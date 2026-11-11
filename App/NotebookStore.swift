import Foundation
import NootyCore
import PencilKit
import UIKit

/// Contenu d'une page hors encre : images, textes, rubans.
typealias PageElements = [PageElement]

/// Lecture et écriture d'un carnet. Chaque page a son fichier : une sauvegarde ne réécrit
/// que les pages dont le contenu a changé, plus le manifeste s'il a changé.
/// Les écritures sont atomiques (fichier temporaire puis renommage).
/// Après `open`, les méthodes d'écriture s'exécutent sur `queue`.
final class NotebookStore {
    struct Opened {
        let store: NotebookStore
        let manifest: NotebookManifest
        /// Traits de chaque page, en repère local à la page.
        let pages: [[Stroke]]
        /// Éléments de chaque page.
        let elements: [PageElements]
        /// Pages dont le fichier était absent ou illisible (mis de côté).
        let damagedPages: Int
    }

    struct SaveResult {
        let pagesWritten: Int
        let strokeCount: Int
        let milliseconds: Double
    }

    let directory: URL
    let queue = DispatchQueue(label: "nooty.notebook-store", qos: .userInitiated)
    private var savedPages: [UUID: [Stroke]] = [:]
    private var savedElements: [UUID: PageElements] = [:]
    private var savedInfo: [UUID: PageInfo] = [:]
    private var savedManifest: NotebookManifest?

    private init(directory: URL) {
        self.directory = directory
    }

    static func manifestURL(_ dir: URL) -> URL { dir.appendingPathComponent("carnet.json") }
    static func pagesURL(_ dir: URL) -> URL { dir.appendingPathComponent("pages", isDirectory: true) }
    static func pageURL(_ dir: URL, _ id: UUID) -> URL { pagesURL(dir).appendingPathComponent("\(id.uuidString).json") }
    static func resourcesURL(_ dir: URL) -> URL { dir.appendingPathComponent("ressources", isDirectory: true) }
    static func indexURL(_ dir: URL) -> URL { dir.appendingPathComponent("index.json") }

    var resourcesDirectory: URL { Self.resourcesURL(directory) }

    func resourceURL(_ name: String) -> URL {
        resourcesDirectory.appendingPathComponent(name)
    }

    /// Copie un fichier dans les ressources et renvoie son nom. Utilisable depuis n'importe quel fil.
    static func addResource(_ data: Data, ext: String, in dir: URL) throws -> String {
        let name = ResourceName.make(ext)
        try FileManager.default.createDirectory(at: resourcesURL(dir), withIntermediateDirectories: true)
        try data.write(to: resourcesURL(dir).appendingPathComponent(name), options: .atomic)
        return name
    }

    func addResource(_ data: Data, ext: String) throws -> String {
        try Self.addResource(data, ext: ext, in: directory)
    }

    static func create(directory: URL, manifest: NotebookManifest, firstPage: Page? = nil) throws {
        try FileManager.default.createDirectory(at: pagesURL(directory), withIntermediateDirectories: true)
        if let firstPage { try PageCodec.encode(firstPage).write(to: pageURL(directory, firstPage.id), options: .atomic) }
        try NotebookCodec.encode(manifest).write(to: manifestURL(directory), options: .atomic)
    }

    static func open(directory: URL) throws -> Opened {
        let manifest = try NotebookCodec.decode(try Data(contentsOf: manifestURL(directory)))
        let store = NotebookStore(directory: directory)
        var pages: [[Stroke]] = []
        var elements: [PageElements] = []
        var damaged = 0
        for info in manifest.pages {
            let url = pageURL(directory, info.id)
            var strokes: [Stroke] = []
            var items: PageElements = []
            if let data = try? Data(contentsOf: url) {
                if let page = try? PageCodec.decode(data) {
                    strokes = page.strokes
                    items = page.elements
                    store.savedPages[info.id] = strokes
                    store.savedElements[info.id] = items
                    store.savedInfo[info.id] = info
                } else {
                    // Page illisible : on la met de côté plutôt que de l'écraser.
                    let aside = url.deletingPathExtension().appendingPathExtension("illisible-\(Int(Date().timeIntervalSince1970)).json")
                    try? FileManager.default.moveItem(at: url, to: aside)
                    damaged += 1
                }
            }
            pages.append(strokes)
            elements.append(items)
        }
        store.savedManifest = manifest
        return Opened(store: store, manifest: manifest, pages: pages, elements: elements, damagedPages: damaged)
    }

    /// Lit une page sans ouvrir le carnet en écriture (miniatures, recherche, export).
    static func readPage(_ dir: URL, _ id: UUID) -> Page? {
        guard let data = try? Data(contentsOf: pageURL(dir, id)) else { return nil }
        return try? PageCodec.decode(data)
    }

    /// Enregistre l'état courant. À appeler sur `queue`.
    func save(drawing: PKDrawing, elements: [PageElements], manifest: NotebookManifest) throws -> SaveResult {
        let converted = drawing.strokes.map { InkConverter.stroke(from: $0) }
        return try save(strokes: converted, elements: elements, manifest: manifest)
    }

    func save(strokes converted: [Stroke], elements: [PageElements], manifest: NotebookManifest) throws -> SaveResult {
        let t0 = CFAbsoluteTimeGetCurrent()
        let layout = PageLayout(pages: manifest.pages)
        // Les identifiants sont conservés sur tout le carnet, y compris pour un trait changé de page.
        let previous = manifest.pages.flatMap { savedPages[$0.id] ?? [] }
        let identified = IdentityMatcher.assignIDs(previous: previous, current: converted)
        let pages = layout.split(identified)

        try FileManager.default.createDirectory(at: Self.pagesURL(directory), withIntermediateDirectories: true)
        var written = 0
        for (i, info) in manifest.pages.enumerated() {
            let strokes = pages[i]
            let items = i < elements.count ? elements[i] : []
            if savedPages[info.id] == strokes, savedElements[info.id] == items, savedInfo[info.id] == info { continue }
            let page = Page(
                id: info.id, width: info.width, height: info.height, background: info.background,
                strokes: strokes, elements: items, updatedAt: nowMs()
            )
            try PageCodec.encode(page).write(to: Self.pageURL(directory, info.id), options: .atomic)
            savedPages[info.id] = strokes
            savedElements[info.id] = items
            savedInfo[info.id] = info
            written += 1
        }
        if savedManifest != manifest {
            try NotebookCodec.encode(manifest).write(to: Self.manifestURL(directory), options: .atomic)
            // Le manifeste est écrit avant le nettoyage : une interruption ne laisse jamais une page référencée sans fichier.
            let keep = Set(manifest.pages.map(\.id))
            for id in Array(savedPages.keys) where !keep.contains(id) {
                try? FileManager.default.removeItem(at: Self.pageURL(directory, id))
                savedPages[id] = nil
                savedElements[id] = nil
                savedInfo[id] = nil
            }
            savedManifest = manifest
        }
        return SaveResult(pagesWritten: written, strokeCount: converted.count, milliseconds: (CFAbsoluteTimeGetCurrent() - t0) * 1000)
    }

    /// Mémorise le contenu tel que le moteur d'encre le restitue juste après l'ouverture,
    /// pour que la première sauvegarde ne réécrive pas des pages inchangées. À appeler sur `queue`.
    func prime(drawing: PKDrawing, manifest: NotebookManifest) {
        let converted = drawing.strokes.map { InkConverter.stroke(from: $0) }
        let previous = manifest.pages.flatMap { savedPages[$0.id] ?? [] }
        let pages = PageLayout(pages: manifest.pages).split(IdentityMatcher.assignIDs(previous: previous, current: converted))
        for (info, strokes) in zip(manifest.pages, pages) where savedPages[info.id] != nil {
            savedPages[info.id] = strokes
        }
    }

    /// Supprime les ressources qui ne sont plus référencées. À appeler sur `queue`, après une sauvegarde.
    func collectGarbage(manifest: NotebookManifest, elements: [PageElements]) {
        let used = manifest.referencedResources.union(elements.flatMap { $0.compactMap(\.resource) })
        let files = (try? FileManager.default.contentsOfDirectory(atPath: resourcesDirectory.path)) ?? []
        for name in files where ResourceName.isValid(name) && !used.contains(name) {
            try? FileManager.default.removeItem(at: resourceURL(name))
        }
    }

    func writeThumbnail(_ image: UIImage) {
        guard let data = image.pngData() else { return }
        try? data.write(to: directory.appendingPathComponent("miniature.png"), options: .atomic)
    }

    func loadIndex() -> NotebookTextIndex {
        (try? Data(contentsOf: Self.indexURL(directory))).map(NotebookTextIndex.decode) ?? NotebookTextIndex()
    }

    func saveIndex(_ index: NotebookTextIndex) {
        try? index.encoded().write(to: Self.indexURL(directory), options: .atomic)
    }

    /// Copie un carnet en donnant de nouveaux identifiants au carnet, à ses pages et à ses traits.
    static func duplicate(from source: URL, to target: URL, newID: UUID) throws {
        let fm = FileManager.default
        let opened = try open(directory: source)
        var manifest = opened.manifest
        manifest.id = newID
        manifest.updatedAt = nowMs()
        try fm.createDirectory(at: pagesURL(target), withIntermediateDirectories: true)
        for i in manifest.pages.indices {
            manifest.pages[i].id = UUID()
            let info = manifest.pages[i]
            let strokes = opened.pages[i].map { s -> Stroke in
                var copy = s
                copy.id = UUID()
                return copy
            }
            let page = Page(id: info.id, width: info.width, height: info.height, background: info.background, strokes: strokes, elements: opened.elements[i], updatedAt: nowMs())
            try PageCodec.encode(page).write(to: pageURL(target, info.id), options: .atomic)
        }
        if fm.fileExists(atPath: resourcesURL(source).path) {
            try fm.copyItem(at: resourcesURL(source), to: resourcesURL(target))
        }
        try NotebookCodec.encode(manifest).write(to: manifestURL(target), options: .atomic)
        for extra in ["miniature.png", "document.rtf", "index.json"] {
            let file = source.appendingPathComponent(extra)
            if fm.fileExists(atPath: file.path) { try? fm.copyItem(at: file, to: target.appendingPathComponent(extra)) }
        }
    }

    // MARK: - Échange

    /// Rassemble tout le carnet dans un fichier d'échange `.nooty`.
    static func export(directory: URL, entry: LibraryEntry) throws -> Data {
        let opened = try open(directory: directory)
        let pages = opened.manifest.pages.enumerated().map { i, info in
            Page(id: info.id, width: info.width, height: info.height, background: info.background, strokes: opened.pages[i], elements: opened.elements[i], updatedAt: nowMs())
        }
        var resources: [String: Data] = [:]
        let needed = opened.manifest.referencedResources.union(opened.elements.flatMap { $0.compactMap(\.resource) })
        for name in needed {
            resources[name] = try Data(contentsOf: resourcesURL(directory).appendingPathComponent(name))
        }
        if let doc = try? Data(contentsOf: directory.appendingPathComponent("document.rtf")) {
            let name = ResourceName.make("rtf")
            resources[name] = doc
        }
        return try ExportCodec.encode(NotebookExport(title: entry.title, kind: entry.kind, color: entry.color, manifest: opened.manifest, pages: pages, resources: resources))
    }

    /// Recrée un carnet à partir d'un fichier d'échange, avec de nouveaux identifiants de carnet et de pages.
    static func importExport(_ export: NotebookExport, into directory: URL, newID: UUID) throws {
        let fm = FileManager.default
        try fm.createDirectory(at: pagesURL(directory), withIntermediateDirectories: true)
        try fm.createDirectory(at: resourcesURL(directory), withIntermediateDirectories: true)
        var manifest = export.manifest
        manifest.id = newID
        for (i, page) in export.pages.enumerated() {
            var copy = page
            copy.id = UUID()
            manifest.pages[i].id = copy.id
            try PageCodec.encode(copy).write(to: pageURL(directory, copy.id), options: .atomic)
        }
        for (name, data) in export.resources {
            if name.hasSuffix(".rtf"), !manifest.referencedResources.contains(name) {
                try data.write(to: directory.appendingPathComponent("document.rtf"), options: .atomic)
            } else {
                try data.write(to: resourcesURL(directory).appendingPathComponent(name), options: .atomic)
            }
        }
        try NotebookCodec.encode(manifest).write(to: manifestURL(directory), options: .atomic)
    }
}
