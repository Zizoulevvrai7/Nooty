import Foundation
import NootyCore
import PencilKit
import UIKit

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
    private var savedInfo: [UUID: PageInfo] = [:]
    private var savedManifest: NotebookManifest?

    private init(directory: URL) {
        self.directory = directory
    }

    private static func manifestURL(_ dir: URL) -> URL { dir.appendingPathComponent("carnet.json") }
    private static func pagesURL(_ dir: URL) -> URL { dir.appendingPathComponent("pages", isDirectory: true) }
    private static func pageURL(_ dir: URL, _ id: UUID) -> URL { pagesURL(dir).appendingPathComponent("\(id.uuidString).json") }

    static func create(directory: URL, manifest: NotebookManifest, firstPage: Page? = nil) throws {
        try FileManager.default.createDirectory(at: pagesURL(directory), withIntermediateDirectories: true)
        if let firstPage { try PageCodec.encode(firstPage).write(to: pageURL(directory, firstPage.id), options: .atomic) }
        try NotebookCodec.encode(manifest).write(to: manifestURL(directory), options: .atomic)
    }

    static func open(directory: URL) throws -> Opened {
        let manifest = try NotebookCodec.decode(try Data(contentsOf: manifestURL(directory)))
        let store = NotebookStore(directory: directory)
        var pages: [[Stroke]] = []
        var damaged = 0
        for info in manifest.pages {
            let url = pageURL(directory, info.id)
            var strokes: [Stroke] = []
            if let data = try? Data(contentsOf: url) {
                if let page = try? PageCodec.decode(data) {
                    strokes = page.strokes
                    store.savedPages[info.id] = strokes
                    store.savedInfo[info.id] = info
                } else {
                    // Page illisible : on la met de côté plutôt que de l'écraser.
                    let aside = url.deletingPathExtension().appendingPathExtension("illisible-\(Int(Date().timeIntervalSince1970)).json")
                    try? FileManager.default.moveItem(at: url, to: aside)
                    damaged += 1
                }
            }
            pages.append(strokes)
        }
        store.savedManifest = manifest
        return Opened(store: store, manifest: manifest, pages: pages, damagedPages: damaged)
    }

    /// Enregistre l'état courant. À appeler sur `queue`.
    func save(drawing: PKDrawing, manifest: NotebookManifest) throws -> SaveResult {
        let converted = drawing.strokes.map { InkConverter.stroke(from: $0) }
        return try save(strokes: converted, manifest: manifest)
    }

    func save(strokes converted: [Stroke], manifest: NotebookManifest) throws -> SaveResult {
        let t0 = CFAbsoluteTimeGetCurrent()
        let layout = PageLayout(pages: manifest.pages)
        // Les identifiants sont conservés sur tout le carnet, y compris pour un trait changé de page.
        let previous = manifest.pages.flatMap { savedPages[$0.id] ?? [] }
        let identified = IdentityMatcher.assignIDs(previous: previous, current: converted)
        let pages = layout.split(identified)

        try FileManager.default.createDirectory(at: Self.pagesURL(directory), withIntermediateDirectories: true)
        var written = 0
        for (info, strokes) in zip(manifest.pages, pages) {
            if savedPages[info.id] == strokes, savedInfo[info.id] == info { continue }
            let page = Page(id: info.id, width: info.width, height: info.height, background: info.background, strokes: strokes, updatedAt: nowMs())
            try PageCodec.encode(page).write(to: Self.pageURL(directory, info.id), options: .atomic)
            savedPages[info.id] = strokes
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

    func writeThumbnail(_ image: UIImage) {
        guard let data = image.pngData() else { return }
        try? data.write(to: directory.appendingPathComponent("miniature.png"), options: .atomic)
    }

    /// Copie un carnet en donnant de nouveaux identifiants au carnet et à ses pages.
    static func duplicate(from source: URL, to target: URL, newID: UUID) throws {
        let opened = try open(directory: source)
        var manifest = opened.manifest
        manifest.id = newID
        manifest.updatedAt = nowMs()
        try FileManager.default.createDirectory(at: pagesURL(target), withIntermediateDirectories: true)
        for i in manifest.pages.indices {
            manifest.pages[i].id = UUID()
            let info = manifest.pages[i]
            let strokes = opened.pages[i].map { s -> Stroke in
                var copy = s
                copy.id = UUID()
                return copy
            }
            let page = Page(id: info.id, width: info.width, height: info.height, background: info.background, strokes: strokes, updatedAt: nowMs())
            try PageCodec.encode(page).write(to: pageURL(target, info.id), options: .atomic)
        }
        try NotebookCodec.encode(manifest).write(to: manifestURL(target), options: .atomic)
        let thumb = source.appendingPathComponent("miniature.png")
        if FileManager.default.fileExists(atPath: thumb.path) {
            try? FileManager.default.copyItem(at: thumb, to: target.appendingPathComponent("miniature.png"))
        }
    }
}
