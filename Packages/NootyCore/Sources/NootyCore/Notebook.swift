import Foundation

/// Fond importé d'une page : une page de PDF ou une image (document scanné, photo).
public enum Backdrop: Equatable, Sendable {
    case pdf(resource: String, pageIndex: Int)
    case image(resource: String)

    public var resource: String {
        switch self {
        case let .pdf(r, _): return r
        case let .image(r): return r
        }
    }
}

/// Description d'une page dans un carnet : identité, dimensions, papier et repères.
public struct PageInfo: Identifiable, Equatable, Sendable {
    public var id: UUID
    public var width: Double
    public var height: Double
    public var background: Background
    /// Fond importé, dessiné par-dessus le papier.
    public var backdrop: Backdrop?
    /// Titre de la page dans le plan ; nil si la page n'y figure pas.
    public var title: String?
    public var bookmarked: Bool

    public init(
        id: UUID = UUID(), width: Double = Page.a4Width, height: Double = Page.a4Height,
        background: Background, backdrop: Backdrop? = nil, title: String? = nil, bookmarked: Bool = false
    ) {
        self.id = id
        self.width = width
        self.height = height
        self.background = background
        self.backdrop = backdrop
        self.title = title
        self.bookmarked = bookmarked
    }
}

/// Formats de page proposés, en points typographiques (portrait).
public enum PaperSize: String, CaseIterable, Sendable {
    case a4, a5, a3, letter, square

    public var portrait: (width: Double, height: Double) {
        switch self {
        case .a4: return (595.28, 841.89)
        case .a5: return (419.53, 595.28)
        case .a3: return (841.89, 1190.55)
        case .letter: return (612, 792)
        case .square: return (700, 700)
        }
    }

    public func size(landscape: Bool) -> (width: Double, height: Double) {
        let p = portrait
        return landscape ? (p.height, p.width) : p
    }
}

/// Manifeste d'un carnet : l'ordre des pages, la position de lecture, les enregistrements
/// audio et les cartes de révision. Le contenu de chaque page est dans son propre fichier.
public struct NotebookManifest: Equatable, Sendable {
    public static let maxPages = 5000

    public var id: UUID
    public var pages: [PageInfo]
    /// Dernière page consultée, pour reprendre la lecture au même endroit.
    public var lastPageIndex: Int
    public var updatedAt: Double
    public var recordings: [AudioRecording]
    public var cards: [Flashcard]

    public init(
        id: UUID = UUID(), pages: [PageInfo], lastPageIndex: Int = 0, updatedAt: Double,
        recordings: [AudioRecording] = [], cards: [Flashcard] = []
    ) {
        self.id = id
        self.pages = pages
        self.lastPageIndex = lastPageIndex
        self.updatedAt = updatedAt
        self.recordings = recordings
        self.cards = cards
    }

    /// Ressources référencées par le manifeste (fonds importés, audio).
    public var referencedResources: Set<String> {
        Set(pages.compactMap { $0.backdrop?.resource } + recordings.map(\.resource))
    }
}

public enum NotebookCodec {
    public static let format = "nooty.notebook"
    public static let maxBytes = 64 * 1024 * 1024

    public static func encode(_ m: NotebookManifest) throws -> Data {
        let file = NotebookFileDTO(format: format, schemaVersion: NootyFormat.schemaVersion, notebook: NotebookDTO(m))
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
        return try file.notebook.validated()
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
    var recordings: [AudioRecordingDTO]?
    var cards: [FlashcardDTO]?

    init(_ m: NotebookManifest) {
        id = m.id.uuidString
        lastPageIndex = m.lastPageIndex
        updatedAt = m.updatedAt
        pages = m.pages.map(PageInfoDTO.init)
        recordings = m.recordings.map(AudioRecordingDTO.init)
        cards = m.cards.map(FlashcardDTO.init)
    }

    func validated() throws -> NotebookManifest {
        guard let nid = UUID(uuidString: id) else { throw FormatError.invalid("identifiant de carnet") }
        try require(!pages.isEmpty && pages.count <= NotebookManifest.maxPages, "nombre de pages")
        try require(updatedAt.isFinite && updatedAt >= 0, "date de modification")
        var seen = Set<UUID>()
        let parsed: [PageInfo] = try pages.map { p in
            let info = try p.validated()
            try require(seen.insert(info.id).inserted, "identifiant de page en double")
            return info
        }
        let recs = try (recordings ?? []).map { try $0.validated() }
        try require(recs.count <= 500, "trop d’enregistrements")
        try require(Set(recs.map(\.id)).count == recs.count, "enregistrement en double")
        let deck = try (cards ?? []).map { try $0.validated() }
        try require(deck.count <= 20_000, "trop de cartes")
        return NotebookManifest(
            id: nid, pages: parsed, lastPageIndex: min(max(0, lastPageIndex), parsed.count - 1),
            updatedAt: updatedAt, recordings: recs, cards: deck
        )
    }
}

struct PageInfoDTO: Codable {
    var id: String
    var width: Double
    var height: Double
    var background: BackgroundDTO
    var backdrop: BackdropDTO?
    var title: String?
    var bookmarked: Bool?

    init(_ p: PageInfo) {
        id = p.id.uuidString
        width = p.width
        height = p.height
        background = BackgroundDTO(p.background)
        backdrop = p.backdrop.map(BackdropDTO.init)
        title = p.title
        bookmarked = p.bookmarked
    }

    func validated() throws -> PageInfo {
        guard let pid = UUID(uuidString: id) else { throw FormatError.invalid("identifiant de page") }
        try require(width.isFinite && (10...20_000).contains(width), "largeur de page")
        try require(height.isFinite && (10...20_000).contains(height), "hauteur de page")
        if let title { try require(title.count <= 300, "titre de page") }
        return PageInfo(
            id: pid, width: width, height: height, background: try background.validated(),
            backdrop: try backdrop?.validated(), title: title.flatMap(LibraryIndex.normalizedTitle),
            bookmarked: bookmarked ?? false
        )
    }
}

struct BackdropDTO: Codable {
    var type: String
    var resource: String
    var pageIndex: Int?

    init(_ b: Backdrop) {
        switch b {
        case let .pdf(r, i):
            type = "pdf"
            resource = r
            pageIndex = i
        case let .image(r):
            type = "image"
            resource = r
        }
    }

    func validated() throws -> Backdrop {
        try require(ResourceName.isValid(resource), "ressource de fond")
        switch type {
        case "pdf":
            let index = pageIndex ?? 0
            try require(index >= 0 && index < 100_000, "page de PDF")
            return .pdf(resource: resource, pageIndex: index)
        case "image":
            return .image(resource: resource)
        default:
            throw FormatError.invalid("type de fond")
        }
    }
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
