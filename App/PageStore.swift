import Foundation
import NootyCore
import PencilKit

/// Stockage de la page du prototype dans le dossier Documents de l'application
/// (visible dans l'app Fichiers : « Sur mon iPad › Nooty »).
///
/// Chaque sauvegarde écrit un fichier temporaire puis le renomme (écriture atomique) :
/// après une interruption, on retrouve l'ancienne ou la nouvelle version, jamais un mélange.
/// Toutes les méthodes s'exécutent sur `queue`.
final class PageStore {
    struct SaveResult {
        let page: Page
        let bytes: Int
        let convertMs: Double
        let totalMs: Double
    }

    let fileURL: URL
    let queue = DispatchQueue(label: "nooty.page-store", qos: .userInitiated)
    /// Derniers traits enregistrés, pour conserver leurs identifiants.
    private var previous: [Stroke] = []

    init(directory: URL) {
        fileURL = directory.appendingPathComponent("page.nooty.json")
    }

    static func defaultDirectory() throws -> URL {
        let docs = try FileManager.default.url(for: .documentDirectory, in: .userDomainMask, appropriateFor: nil, create: true)
        let dir = docs.appendingPathComponent("Prototype", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    func load() throws -> Page? {
        guard FileManager.default.fileExists(atPath: fileURL.path) else { return nil }
        let page = try PageCodec.decode(try Data(contentsOf: fileURL))
        previous = page.strokes
        return page
    }

    /// Met de côté un fichier illisible au lieu de l'écraser. Retourne son nouveau nom.
    func quarantine() -> String? {
        let name = "page.illisible-\(Int(Date().timeIntervalSince1970)).json"
        let target = fileURL.deletingLastPathComponent().appendingPathComponent(name)
        do {
            try FileManager.default.moveItem(at: fileURL, to: target)
            return name
        } catch {
            return nil
        }
    }

    func save(drawing: PKDrawing, pageID: UUID, size: CGSize, background: Background) throws -> SaveResult {
        let t0 = CFAbsoluteTimeGetCurrent()
        let converted = drawing.strokes.map { InkConverter.stroke(from: $0) }
        let strokes = IdentityMatcher.assignIDs(previous: previous, current: converted)
        let page = Page(
            id: pageID, width: size.width, height: size.height, background: background,
            strokes: strokes, updatedAt: (Date().timeIntervalSince1970 * 1000).rounded()
        )
        let data = try PageCodec.encode(page)
        let t1 = CFAbsoluteTimeGetCurrent()
        try data.write(to: fileURL, options: .atomic)
        previous = strokes
        let t2 = CFAbsoluteTimeGetCurrent()
        return SaveResult(page: page, bytes: data.count, convertMs: (t1 - t0) * 1000, totalMs: (t2 - t0) * 1000)
    }
}
