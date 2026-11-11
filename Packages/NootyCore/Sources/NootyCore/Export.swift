import Foundation

/// Fichier d'échange `.nooty` : un bloc-notes complet (manifeste, pages, ressources, audio)
/// dans un seul fichier JSON. Les ressources sont encodées en base64.
public struct NotebookExport: Equatable, Sendable {
    public var title: String
    public var kind: LibraryEntryKind
    public var color: RGBA
    public var manifest: NotebookManifest
    public var pages: [Page]
    /// Nom de fichier → contenu.
    public var resources: [String: Data]

    public init(title: String, kind: LibraryEntryKind, color: RGBA, manifest: NotebookManifest, pages: [Page], resources: [String: Data]) {
        self.title = title
        self.kind = kind
        self.color = color
        self.manifest = manifest
        self.pages = pages
        self.resources = resources
    }
}

public enum ExportCodec {
    public static let format = "nooty.export"
    public static let maxBytes = 1024 * 1024 * 1024

    public static func encode(_ e: NotebookExport) throws -> Data {
        let dto = ExportDTO(
            format: format, schemaVersion: NootyFormat.schemaVersion, title: e.title, kind: e.kind.rawValue,
            color: e.color.hex, notebook: NotebookDTO(e.manifest), pages: try e.pages.map(PageDTO.init),
            resources: e.resources.keys.sorted().map { ResourceDTO(name: $0, data: e.resources[$0]!) }
        )
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        return try encoder.encode(dto)
    }

    /// Valide entièrement le fichier : structure, pages présentes et uniques, ressources référencées présentes.
    public static func decode(_ data: Data) throws -> NotebookExport {
        try checkHeader(data, format: format, maxBytes: maxBytes, currentVersion: NootyFormat.schemaVersion)
        let dto: ExportDTO
        do {
            dto = try JSONDecoder().decode(ExportDTO.self, from: data)
        } catch {
            throw FormatError.invalid("structure")
        }
        guard let title = LibraryIndex.normalizedTitle(dto.title) else { throw FormatError.invalid("titre") }
        guard let kind = LibraryEntryKind(rawValue: dto.kind), kind.hasFiles else { throw FormatError.invalid("type de document") }
        guard let color = RGBA(hex: dto.color) else { throw FormatError.invalid("couleur") }
        let manifest = try dto.notebook.validated()
        let pages = try dto.pages.map { try $0.validated() }
        try require(pages.count == manifest.pages.count, "nombre de pages")
        let byID = Dictionary(pages.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
        try require(byID.count == pages.count, "page en double")
        let ordered = try manifest.pages.map { info -> Page in
            guard let p = byID[info.id] else { throw FormatError.invalid("page manquante") }
            return p
        }
        var resources: [String: Data] = [:]
        for r in dto.resources {
            try require(ResourceName.isValid(r.name), "nom de ressource")
            try require(resources[r.name] == nil, "ressource en double")
            resources[r.name] = r.data
        }
        let needed = manifest.referencedResources.union(ordered.flatMap { $0.elements.compactMap(\.resource) })
        try require(needed.isSubset(of: Set(resources.keys)), "ressource manquante")
        return NotebookExport(title: title, kind: kind, color: color, manifest: manifest, pages: ordered, resources: resources)
    }
}

struct ResourceDTO: Codable {
    var name: String
    var data: Data
}

struct ExportDTO: Codable {
    var format: String
    var schemaVersion: Int
    var title: String
    var kind: String
    var color: String
    var notebook: NotebookDTO
    var pages: [PageDTO]
    var resources: [ResourceDTO]
}
