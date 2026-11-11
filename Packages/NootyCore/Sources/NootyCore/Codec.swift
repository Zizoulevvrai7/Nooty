import Foundation

public enum FormatError: Error, Equatable, LocalizedError {
    case tooLarge
    case notNooty
    case unsupportedVersion(Int)
    case invalid(String)

    public var errorDescription: String? {
        switch self {
        case .tooLarge: return "Fichier trop volumineux."
        case .notNooty: return "Ce fichier n’est pas une page Nooty."
        case let .unsupportedVersion(v): return "Version de format \(v) non prise en charge par cette version de l’application."
        case let .invalid(what): return "Fichier invalide : \(what)."
        }
    }
}

/// Lecture et écriture d'une page au format d'échange JSON.
///
/// Les points sont regroupés en binaire (Float32 petit-boutiste, `InkPoint.componentCount`
/// composantes par point) encodé en base64 : compact, rapide, et décrit dans la documentation.
/// Toute entrée est traitée comme non fiable et validée.
public enum PageCodec {
    public static let maxBytes = 256 * 1024 * 1024
    public static let maxStrokes = 200_000
    public static let maxPointsPerStroke = 100_000
    public static let maxMaskElements = 10_000
    public static let maxElements = 5_000

    public static func encode(_ page: Page) throws -> Data {
        let file = PageFileDTO(format: NootyFormat.pageFormat, schemaVersion: NootyFormat.schemaVersion, page: try PageDTO(page))
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        return try encoder.encode(file)
    }

    public static func decode(_ data: Data) throws -> Page {
        try checkHeader(data, format: NootyFormat.pageFormat, maxBytes: maxBytes, currentVersion: NootyFormat.schemaVersion)
        // Version 1 → 2 : ajout des éléments (images, textes, rubans), absents en version 1.
        let file: PageFileDTO
        do {
            file = try JSONDecoder().decode(PageFileDTO.self, from: data)
        } catch {
            throw FormatError.invalid("structure")
        }
        return try file.page.validated()
    }
}

// MARK: - Points

public enum PointPacking {
    public static func pack(_ points: [InkPoint]) throws -> String {
        var words = [UInt32]()
        words.reserveCapacity(points.count * InkPoint.componentCount)
        for p in points {
            for v in p.components {
                guard v.isFinite else { throw FormatError.invalid("valeur de point non finie") }
                words.append(Float32(v).bitPattern.littleEndian)
            }
        }
        return words.withUnsafeBufferPointer { Data(buffer: $0) }.base64EncodedString()
    }

    public static func unpack(_ text: String, maxPoints: Int = PageCodec.maxPointsPerStroke) throws -> [InkPoint] {
        guard let data = Data(base64Encoded: text) else { throw FormatError.invalid("points illisibles") }
        let stride = InkPoint.componentCount * 4
        guard data.count > 0, data.count % stride == 0 else { throw FormatError.invalid("nombre de composantes des points") }
        let count = data.count / stride
        guard count <= maxPoints else { throw FormatError.invalid("trop de points dans un trait") }
        var words = [UInt32](repeating: 0, count: data.count / 4)
        _ = words.withUnsafeMutableBytes { data.copyBytes(to: $0) }
        let values = words.map { Double(Float32(bitPattern: UInt32(littleEndian: $0))) }
        guard values.allSatisfy(\.isFinite) else { throw FormatError.invalid("valeur de point non finie") }
        return (0..<count).map { InkPoint(components: values, at: $0 * InkPoint.componentCount) }
    }
}

// MARK: - Représentation d'échange

struct Header: Decodable {
    let format: String
    let schemaVersion: Int
}

struct PageFileDTO: Codable {
    var format: String
    var schemaVersion: Int
    var page: PageDTO
}

struct BackgroundDTO: Codable {
    var kind: String
    var color: String
    var lineColor: String
    var spacing: Double
}

struct PathElementDTO: Codable {
    var op: String
    var p: [Double]
}

struct StrokeDTO: Codable {
    var id: String
    var tool: String
    var color: String
    var transform: [Double]
    var mask: [PathElementDTO]?
    var createdAt: Double
    var randomSeed: UInt32
    var pointComponents: Int
    var points: String
}

struct PageDTO: Codable {
    var id: String
    var width: Double
    var height: Double
    var background: BackgroundDTO
    var updatedAt: Double
    var strokes: [StrokeDTO]
    var elements: [PageElementDTO]?
}

func require(_ condition: Bool, _ what: @autoclosure () -> String) throws {
    if !condition { throw FormatError.invalid(what()) }
}

/// Vérifie l'en-tête commun à tous les fichiers Nooty avant toute analyse du contenu.
func checkHeader(_ data: Data, format: String, maxBytes: Int, currentVersion: Int) throws {
    guard data.count <= maxBytes else { throw FormatError.tooLarge }
    let header: Header
    do {
        header = try JSONDecoder().decode(Header.self, from: data)
    } catch {
        throw FormatError.notNooty
    }
    guard header.format == format else { throw FormatError.notNooty }
    guard header.schemaVersion >= 1 else { throw FormatError.invalid("version de schéma") }
    guard header.schemaVersion <= currentVersion else { throw FormatError.unsupportedVersion(header.schemaVersion) }
}

extension BackgroundDTO {
    init(_ b: Background) {
        self.init(kind: b.kind.rawValue, color: b.color.hex, lineColor: b.lineColor.hex, spacing: b.spacing)
    }

    func validated() throws -> Background {
        guard let kind = BackgroundKind(rawValue: kind),
              let color = RGBA(hex: color),
              let lineColor = RGBA(hex: lineColor) else { throw FormatError.invalid("fond de page") }
        try require(spacing.isFinite && (2...500).contains(spacing), "espacement du fond")
        return Background(kind: kind, color: color, lineColor: lineColor, spacing: spacing)
    }
}

extension PageDTO {
    init(_ page: Page) throws {
        id = page.id.uuidString
        width = page.width
        height = page.height
        background = BackgroundDTO(page.background)
        updatedAt = page.updatedAt
        strokes = try page.strokes.map { s in
            StrokeDTO(
                id: s.id.uuidString, tool: s.tool.rawValue, color: s.color.hex, transform: s.transform.values,
                mask: s.mask.map { $0.map(PathElementDTO.init) }, createdAt: s.createdAt, randomSeed: s.randomSeed,
                pointComponents: InkPoint.componentCount, points: try PointPacking.pack(s.points)
            )
        }
        elements = page.elements.map(PageElementDTO.init)
    }

    func validated() throws -> Page {
        guard let pageID = UUID(uuidString: id) else { throw FormatError.invalid("identifiant de page") }
        try require(width.isFinite && (10...20_000).contains(width), "largeur de page")
        try require(height.isFinite && (10...20_000).contains(height), "hauteur de page")
        try require(updatedAt.isFinite && updatedAt >= 0, "date de modification")
        try require(strokes.count <= PageCodec.maxStrokes, "trop de traits")
        let bg = try background.validated()

        var seen = Set<UUID>()
        let parsed: [Stroke] = try strokes.map { dto in
            let stroke = try dto.validated()
            try require(seen.insert(stroke.id).inserted, "identifiant de trait en double")
            return stroke
        }
        let rawElements = elements ?? []
        try require(rawElements.count <= PageCodec.maxElements, "trop d’éléments")
        let parsedElements = try rawElements.map { dto in
            let e = try dto.validated()
            try require(seen.insert(e.id).inserted, "identifiant d’élément en double")
            return e
        }
        return Page(
            id: pageID, width: width, height: height,
            background: bg,
            strokes: parsed, elements: parsedElements, updatedAt: updatedAt
        )
    }
}

extension StrokeDTO {
    func validated() throws -> Stroke {
        guard let strokeID = UUID(uuidString: id) else { throw FormatError.invalid("identifiant de trait") }
        guard let inkTool = InkTool(rawValue: tool) else { throw FormatError.invalid("outil inconnu") }
        guard let rgba = RGBA(hex: color) else { throw FormatError.invalid("couleur") }
        try require(transform.count == 6 && transform.allSatisfy(\.isFinite), "transformation")
        try require(createdAt.isFinite && createdAt >= 0, "date du trait")
        try require(pointComponents == InkPoint.componentCount, "composantes des points")
        let pts = try PointPacking.unpack(points)
        var elements: [PathElement]?
        if let mask {
            try require(mask.count <= PageCodec.maxMaskElements, "masque trop complexe")
            elements = try mask.map { try $0.validated() }
            if let first = elements?.first {
                try require({ if case .move = first { return true } else { return false } }(), "masque sans point de départ")
            }
        }
        return Stroke(
            id: strokeID, tool: inkTool, color: rgba, points: pts,
            transform: AffineMatrix(a: transform[0], b: transform[1], c: transform[2], d: transform[3], tx: transform[4], ty: transform[5]),
            mask: elements, createdAt: createdAt, randomSeed: randomSeed
        )
    }
}

extension PathElementDTO {
    init(_ e: PathElement) {
        switch e {
        case let .move(x, y): self.init(op: "m", p: [x, y])
        case let .line(x, y): self.init(op: "l", p: [x, y])
        case let .quad(cx, cy, x, y): self.init(op: "q", p: [cx, cy, x, y])
        case let .cubic(c1x, c1y, c2x, c2y, x, y): self.init(op: "c", p: [c1x, c1y, c2x, c2y, x, y])
        case .close: self.init(op: "z", p: [])
        }
    }

    func validated() throws -> PathElement {
        try require(p.allSatisfy(\.isFinite), "masque")
        switch (op, p.count) {
        case ("m", 2): return .move(p[0], p[1])
        case ("l", 2): return .line(p[0], p[1])
        case ("q", 4): return .quad(p[0], p[1], p[2], p[3])
        case ("c", 6): return .cubic(p[0], p[1], p[2], p[3], p[4], p[5])
        case ("z", 0): return .close
        default: throw FormatError.invalid("élément de masque")
        }
    }
}
