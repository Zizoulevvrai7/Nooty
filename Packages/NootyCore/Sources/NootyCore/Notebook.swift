import Foundation

/// Description d'une page dans un carnet : identité, dimensions et papier.
public struct PageInfo: Identifiable, Equatable, Sendable {
    public var id: UUID
    public var width: Double
    public var height: Double
    public var background: Background

    public init(id: UUID = UUID(), width: Double = Page.a4Width, height: Double = Page.a4Height, background: Background) {
        self.id = id
        self.width = width
        self.height = height
        self.background = background
    }
}

/// Manifeste d'un carnet : l'ordre des pages et la position de lecture.
/// Le contenu de chaque page est dans son propre fichier.
public struct NotebookManifest: Equatable, Sendable {
    public static let maxPages = 5000

    public var id: UUID
    public var pages: [PageInfo]
    /// Dernière page consultée, pour reprendre la lecture au même endroit.
    public var lastPageIndex: Int
    public var updatedAt: Double

    public init(id: UUID = UUID(), pages: [PageInfo], lastPageIndex: Int = 0, updatedAt: Double) {
        self.id = id
        self.pages = pages
        self.lastPageIndex = lastPageIndex
        self.updatedAt = updatedAt
    }
}

public enum NotebookCodec {
    public static let format = "nooty.notebook"
    public static let maxBytes = 16 * 1024 * 1024

    public static func encode(_ m: NotebookManifest) throws -> Data {
        let file = NotebookFileDTO(
            format: format, schemaVersion: NootyFormat.schemaVersion,
            notebook: NotebookDTO(
                id: m.id.uuidString, lastPageIndex: m.lastPageIndex, updatedAt: m.updatedAt,
                pages: m.pages.map { PageInfoDTO(id: $0.id.uuidString, width: $0.width, height: $0.height, background: BackgroundDTO($0.background)) }
            )
        )
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        return try encoder.encode(file)
    }

    public static func decode(_ data: Data) throws -> NotebookManifest {
        try checkHeader(data, format: format, maxBytes: maxBytes, currentVersion: NootyFormat.schemaVersion)
        let file: NotebookFileDTO
        do {
            file = try JSONDecoder().decode(NotebookFileDTO.self, from: data)
        } catch {
            throw FormatError.invalid("structure")
        }
        let n = file.notebook
        guard let id = UUID(uuidString: n.id) else { throw FormatError.invalid("identifiant de carnet") }
        try require(!n.pages.isEmpty && n.pages.count <= NotebookManifest.maxPages, "nombre de pages")
        try require(n.updatedAt.isFinite && n.updatedAt >= 0, "date de modification")
        var seen = Set<UUID>()
        let pages: [PageInfo] = try n.pages.map { p in
            guard let pid = UUID(uuidString: p.id) else { throw FormatError.invalid("identifiant de page") }
            try require(seen.insert(pid).inserted, "identifiant de page en double")
            try require(p.width.isFinite && (10...20_000).contains(p.width), "largeur de page")
            try require(p.height.isFinite && (10...20_000).contains(p.height), "hauteur de page")
            return PageInfo(id: pid, width: p.width, height: p.height, background: try p.background.validated())
        }
        return NotebookManifest(
            id: id, pages: pages,
            lastPageIndex: min(max(0, n.lastPageIndex), pages.count - 1), updatedAt: n.updatedAt
        )
    }
}

struct NotebookFileDTO: Codable {
    var format: String
    var schemaVersion: Int
    var notebook: NotebookDTO
}

struct NotebookDTO: Codable {
    var id: String
    var lastPageIndex: Int
    var updatedAt: Double
    var pages: [PageInfoDTO]
}

struct PageInfoDTO: Codable {
    var id: String
    var width: Double
    var height: Double
    var background: BackgroundDTO
}

// MARK: - Disposition des pages

/// Disposition verticale des pages d'un carnet sur une surface d'écriture continue.
/// Les pages sont centrées horizontalement et séparées par un intervalle.
public struct PageLayout: Equatable, Sendable {
    public struct Frame: Equatable, Sendable {
        public var x, y, width, height: Double
        public var midY: Double { y + height / 2 }
        public var maxY: Double { y + height }
    }

    public let frames: [Frame]
    public let width: Double
    public let height: Double
    public let gap: Double

    public init(sizes: [(width: Double, height: Double)], gap: Double = 18) {
        self.gap = gap
        let maxWidth = sizes.map(\.width).max() ?? 0
        var y = 0.0
        var out: [Frame] = []
        for s in sizes {
            out.append(Frame(x: (maxWidth - s.width) / 2, y: y, width: s.width, height: s.height))
            y += s.height + gap
        }
        frames = out
        width = maxWidth
        height = max(0, y - gap)
    }

    public init(pages: [PageInfo], gap: Double = 18) {
        self.init(sizes: pages.map { (width: $0.width, height: $0.height) }, gap: gap)
    }

    /// Page contenant l'ordonnée donnée, sinon la plus proche.
    public func pageIndex(atY y: Double) -> Int {
        var best = 0
        var bestDistance = Double.infinity
        for (i, f) in frames.enumerated() {
            if y >= f.y && y <= f.maxY { return i }
            let d = y < f.y ? f.y - y : y - f.maxY
            if d < bestDistance {
                bestDistance = d
                best = i
            }
        }
        return best
    }

    /// Un trait appartient à la page qui contient le centre de sa boîte englobante.
    public func pageIndex(for stroke: Stroke) -> Int {
        guard let b = stroke.bounds else { return 0 }
        return pageIndex(atY: (b.minY + b.maxY) / 2)
    }

    private static func snap(_ v: Double) -> Double { (v * 1_000_000).rounded() / 1_000_000 }

    /// Répartit les traits de la surface continue par page, en repère local à chaque page.
    /// Seule la transformation est modifiée : les points ne sont jamais réécrits.
    public func split(_ strokes: [Stroke]) -> [[Stroke]] {
        var pages = [[Stroke]](repeating: [], count: frames.count)
        guard !frames.isEmpty else { return pages }
        for stroke in strokes {
            let i = pageIndex(for: stroke)
            var s = stroke
            // Arrondi au millionième : l'aller-retour page ↔ surface redonne exactement la même valeur.
            s.transform.tx = Self.snap(s.transform.tx - frames[i].x)
            s.transform.ty = Self.snap(s.transform.ty - frames[i].y)
            pages[i].append(s)
        }
        return pages
    }

    /// Opération inverse : replace les traits de chaque page sur la surface continue.
    public func place(_ pages: [[Stroke]]) -> [Stroke] {
        var out: [Stroke] = []
        for (i, strokes) in pages.enumerated() where i < frames.count {
            for stroke in strokes {
                var s = stroke
                s.transform.tx += frames[i].x
                s.transform.ty += frames[i].y
                out.append(s)
            }
        }
        return out
    }
}
