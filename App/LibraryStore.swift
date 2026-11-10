import Foundation
import NootyCore
import UIKit

/// Bibliothèque sur disque, dans le dossier Documents de l'application :
///
///     Bibliotheque/bibliotheque.json            index (dossiers, carnets, corbeille)
///     Bibliotheque/carnets/<id>/carnet.json     manifeste du carnet
///     Bibliotheque/carnets/<id>/pages/<id>.json contenu de chaque page
///     Bibliotheque/carnets/<id>/miniature.png   dérivée, reconstructible
///
/// Toutes les écritures sont atomiques. À utiliser sur le fil principal.
final class LibraryStore {
    static let didChange = Notification.Name("nooty.library.didChange")

    let root: URL
    private(set) var index = LibraryIndex()
    /// Message à présenter si l'index était illisible au démarrage.
    private(set) var startupWarning: String?

    private var indexURL: URL { root.appendingPathComponent("bibliotheque.json") }
    private var notebooksURL: URL { root.appendingPathComponent("carnets", isDirectory: true) }

    init(root: URL) {
        self.root = root
        let fm = FileManager.default
        try? fm.createDirectory(at: notebooksURL, withIntermediateDirectories: true)
        if fm.fileExists(atPath: indexURL.path) {
            do {
                index = try LibraryCodec.decode(try Data(contentsOf: indexURL))
            } catch {
                // Index illisible : on le met de côté et on reconstruit à partir des carnets présents.
                let aside = root.appendingPathComponent("bibliotheque.illisible-\(Int(Date().timeIntervalSince1970)).json")
                try? fm.moveItem(at: indexURL, to: aside)
                rebuildFromDisk()
                startupWarning = L("library.rebuilt", aside.lastPathComponent)
            }
        }
    }

    static func defaultRoot() throws -> URL {
        let docs = try FileManager.default.url(for: .documentDirectory, in: .userDomainMask, appropriateFor: nil, create: true)
        return docs.appendingPathComponent("Bibliotheque", isDirectory: true)
    }

    func notebookDirectory(_ id: UUID) -> URL {
        notebooksURL.appendingPathComponent(id.uuidString, isDirectory: true)
    }

    func thumbnailURL(_ id: UUID) -> URL {
        notebookDirectory(id).appendingPathComponent("miniature.png")
    }

    /// L'index est reconstructible : chaque dossier de carnet présent redevient une entrée.
    private func rebuildFromDisk() {
        index = LibraryIndex()
        let dirs = (try? FileManager.default.contentsOfDirectory(at: notebooksURL, includingPropertiesForKeys: nil)) ?? []
        for (n, dir) in dirs.enumerated() {
            guard let id = UUID(uuidString: dir.lastPathComponent),
                  FileManager.default.fileExists(atPath: dir.appendingPathComponent("carnet.json").path) else { continue }
            index.add(LibraryEntry(
                id: id, kind: .notebook, title: index.uniqueTitle(L("library.recovered"), in: nil),
                createdAt: nowMs(), color: Theme.coverColors[n % Theme.coverColors.count]
            ))
        }
        save()
    }

    private func save() {
        do {
            try LibraryCodec.encode(index).write(to: indexURL, options: .atomic)
        } catch {
            startupWarning = L("save.error", error.localizedDescription)
        }
    }

    /// Applique une modification à l'index, l'enregistre et prévient l'interface.
    func mutate(_ body: (inout LibraryIndex) -> Void) {
        body(&index)
        save()
        NotificationCenter.default.post(name: Self.didChange, object: self)
    }

    private func nextColor() -> RGBA {
        Theme.coverColors[index.items.count % Theme.coverColors.count]
    }

    @discardableResult
    func createFolder(title: String, parent: UUID?) -> LibraryEntry {
        let clean = LibraryIndex.normalizedTitle(title) ?? L("library.newFolder")
        let item = LibraryEntry(kind: .folder, parentID: parent, title: index.uniqueTitle(clean, in: parent), createdAt: nowMs(), color: nextColor())
        mutate { $0.add(item) }
        return item
    }

    func createNotebook(title: String, parent: UUID?, background: Background) throws -> LibraryEntry {
        let clean = LibraryIndex.normalizedTitle(title) ?? L("library.untitled")
        let item = LibraryEntry(kind: .notebook, parentID: parent, title: index.uniqueTitle(clean, in: parent), createdAt: nowMs(), color: nextColor())
        let manifest = NotebookManifest(id: item.id, pages: [PageInfo(background: background)], updatedAt: nowMs())
        try NotebookStore.create(directory: notebookDirectory(item.id), manifest: manifest)
        // Miniature initiale : le papier choisi, pour que la couverture ne soit jamais vide.
        let paper = PaperRenderer.image(background, pageSize: CGSize(width: Page.a4Width, height: Page.a4Height), width: 336)
        try? paper.pngData()?.write(to: thumbnailURL(item.id), options: .atomic)
        mutate { $0.add(item) }
        return item
    }

    func duplicateNotebook(_ id: UUID) throws {
        guard let source = index.item(id), source.kind == .notebook else { return }
        let copy = LibraryEntry(
            kind: .notebook, parentID: source.parentID,
            title: index.uniqueTitle(L("library.copyOf", source.title), in: source.parentID),
            createdAt: nowMs(), color: source.color
        )
        try NotebookStore.duplicate(from: notebookDirectory(id), to: notebookDirectory(copy.id), newID: copy.id)
        mutate { $0.add(copy) }
    }

    func deletePermanently(_ id: UUID) {
        var removed: [UUID] = []
        mutate { removed = $0.deletePermanently(id) }
        for notebook in removed { try? FileManager.default.removeItem(at: notebookDirectory(notebook)) }
    }

    func emptyTrash() {
        for item in index.trashed() { deletePermanently(item.id) }
    }

    /// Reprend la page du premier prototype, si elle existe, dans un carnet.
    func importPrototypePageIfNeeded() {
        let fm = FileManager.default
        guard index.items.isEmpty,
              let docs = try? fm.url(for: .documentDirectory, in: .userDomainMask, appropriateFor: nil, create: false) else { return }
        let old = docs.appendingPathComponent("Prototype/page.nooty.json")
        guard let data = try? Data(contentsOf: old), var page = try? PageCodec.decode(data), page.strokes.count < 2000 else { return }
        let item = LibraryEntry(kind: .notebook, title: L("library.prototype"), createdAt: nowMs(), color: Theme.coverColors[0])
        page.id = UUID()
        let info = PageInfo(id: page.id, width: page.width, height: page.height, background: page.background)
        do {
            try NotebookStore.create(directory: notebookDirectory(item.id), manifest: NotebookManifest(id: item.id, pages: [info], updatedAt: nowMs()), firstPage: page)
            mutate { $0.add(item) }
            try? fm.removeItem(at: old.deletingLastPathComponent())
        } catch {
            try? fm.removeItem(at: notebookDirectory(item.id))
        }
    }
}
