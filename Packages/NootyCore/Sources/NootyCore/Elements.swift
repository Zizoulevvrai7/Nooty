import Foundation

/// Rectangle en points typographiques, repère de la page.
public struct Rect: Equatable, Sendable {
    public var x, y, width, height: Double

    public init(x: Double, y: Double, width: Double, height: Double) {
        self.x = x
        self.y = y
        self.width = width
        self.height = height
    }

    public var midX: Double { x + width / 2 }
    public var midY: Double { y + height / 2 }
    public var maxX: Double { x + width }
    public var maxY: Double { y + height }

    public func contains(_ px: Double, _ py: Double) -> Bool {
        px >= x && px <= maxX && py >= y && py <= maxY
    }

    var isValid: Bool {
        [x, y, width, height].allSatisfy(\.isFinite) && width >= 1 && height >= 1 && width <= 40_000 && height <= 40_000
    }
}

public enum TextAlignment: String, CaseIterable, Sendable {
    case left, center, right
}

/// Police d'une zone de texte. Les quatre premières suivent le système ; les autres désignent
/// une famille installée sur l'appareil. Une valeur inconnue (fichier plus récent) se lit `system`.
public enum FontFamily: String, CaseIterable, Sendable {
    case system, serif, rounded, monospaced
    // Linéales
    case avenir, futura, gillSans, helvetica, optima, trebuchet, verdana
    // À empattements
    case georgia, baskerville, palatino, didot, bodoni, hoefler, charter, cochin, times
    // Machine et chasse fixe
    case typewriter, courier, menlo
    // Manuscrites et fantaisie
    case chalkboard, markerFelt, noteworthy, bradleyHand, snellRoundhand, savoye, zapfino, chalkduster
    // Affiche
    case rockwell, copperplate, papyrus, party
}

/// Zone de texte libre ou note repositionnable (si `fill` est défini).
public struct TextElement: Identifiable, Equatable, Sendable {
    public static let maxLength = 100_000

    public var id: UUID
    public var frame: Rect
    /// Rotation en radians autour du centre.
    public var rotation: Double
    public var text: String
    public var font: FontFamily
    public var fontSize: Double
    public var color: RGBA
    public var bold: Bool
    public var italic: Bool
    public var underline: Bool
    public var alignment: TextAlignment
    /// Fond coloré : présent pour une note repositionnable.
    public var fill: RGBA?

    public init(
        id: UUID = UUID(), frame: Rect, rotation: Double = 0, text: String = "", font: FontFamily = .system,
        fontSize: Double = 16, color: RGBA = .ink, bold: Bool = false, italic: Bool = false,
        underline: Bool = false, alignment: TextAlignment = .left, fill: RGBA? = nil
    ) {
        self.id = id
        self.frame = frame
        self.rotation = rotation
        self.text = text
        self.font = font
        self.fontSize = fontSize
        self.color = color
        self.bold = bold
        self.italic = italic
        self.underline = underline
        self.alignment = alignment
        self.fill = fill
    }
}

/// Image insérée. La source est conservée telle quelle dans les ressources du bloc-notes.
public struct ImageElement: Identifiable, Equatable, Sendable {
    public var id: UUID
    public var frame: Rect
    public var rotation: Double
    /// Nom du fichier dans les ressources du bloc-notes.
    public var resource: String
    /// Recadrage en coordonnées normalisées (0 à 1) de l'image source ; nil : image entière.
    public var crop: Rect?

    public init(id: UUID = UUID(), frame: Rect, rotation: Double = 0, resource: String, crop: Rect? = nil) {
        self.id = id
        self.frame = frame
        self.rotation = rotation
        self.resource = resource
        self.crop = crop
    }
}

/// Ruban de masquage pour réviser : il cache ce qui est dessous sans le modifier.
public struct TapeElement: Identifiable, Equatable, Sendable {
    public var id: UUID
    public var frame: Rect
    public var color: RGBA
    /// Vrai si le contenu masqué est actuellement visible.
    public var revealed: Bool

    public init(id: UUID = UUID(), frame: Rect, color: RGBA, revealed: Bool = false) {
        self.id = id
        self.frame = frame
        self.color = color
        self.revealed = revealed
    }
}

public enum PageElement: Identifiable, Equatable, Sendable {
    case image(ImageElement)
    case text(TextElement)
    case tape(TapeElement)

    public var id: UUID {
        switch self {
        case let .image(e): return e.id
        case let .text(e): return e.id
        case let .tape(e): return e.id
        }
    }

    public var frame: Rect {
        get {
            switch self {
            case let .image(e): return e.frame
            case let .text(e): return e.frame
            case let .tape(e): return e.frame
            }
        }
        set {
            switch self {
            case var .image(e): e.frame = newValue; self = .image(e)
            case var .text(e): e.frame = newValue; self = .text(e)
            case var .tape(e): e.frame = newValue; self = .tape(e)
            }
        }
    }

    public var resource: String? {
        if case let .image(e) = self { return e.resource }
        return nil
    }

    /// Texte indexable pour la recherche.
    public var searchableText: String? {
        if case let .text(e) = self { return e.text }
        return nil
    }
}

/// Fichiers de ressources : un identifiant et une extension connue, rien d'autre (pas de chemin).
public enum ResourceName {
    public static let allowedExtensions: Set<String> = ["png", "jpg", "jpeg", "heic", "pdf", "m4a", "rtf"]

    public static func make(_ ext: String) -> String {
        "\(UUID().uuidString).\(ext.lowercased())"
    }

    public static func isValid(_ name: String) -> Bool {
        let parts = name.split(separator: ".", omittingEmptySubsequences: false)
        guard parts.count == 2, UUID(uuidString: String(parts[0])) != nil else { return false }
        return allowedExtensions.contains(parts[1].lowercased())
    }
}

// MARK: - Format d'échange

struct RectDTO: Codable {
    var x, y, w, h: Double

    init(_ r: Rect) {
        x = r.x
        y = r.y
        w = r.width
        h = r.height
    }

    func validated(_ what: String) throws -> Rect {
        let r = Rect(x: x, y: y, width: w, height: h)
        try require(r.isValid, what)
        return r
    }
}

struct PageElementDTO: Codable {
    var type: String
    var id: String
    var frame: RectDTO
    var rotation: Double?
    // Texte
    var text: String?
    var font: String?
    var fontSize: Double?
    var color: String?
    var bold: Bool?
    var italic: Bool?
    var underline: Bool?
    var alignment: String?
    var fill: String?
    // Image
    var resource: String?
    var crop: RectDTO?
    // Ruban
    var revealed: Bool?

    init(_ e: PageElement) {
        id = e.id.uuidString
        frame = RectDTO(e.frame)
        switch e {
        case let .image(i):
            type = "image"
            rotation = i.rotation
            resource = i.resource
            crop = i.crop.map(RectDTO.init)
        case let .text(t):
            type = "text"
            rotation = t.rotation
            text = t.text
            font = t.font.rawValue
            fontSize = t.fontSize
            color = t.color.hex
            bold = t.bold
            italic = t.italic
            underline = t.underline
            alignment = t.alignment.rawValue
            fill = t.fill?.hex
        case let .tape(t):
            type = "tape"
            color = t.color.hex
            revealed = t.revealed
        }
    }

    func validated() throws -> PageElement {
        guard let uuid = UUID(uuidString: id) else { throw FormatError.invalid("identifiant d’élément") }
        let r = try frame.validated("cadre d’élément")
        let angle = rotation ?? 0
        try require(angle.isFinite, "rotation")
        switch type {
        case "image":
            guard let resource, ResourceName.isValid(resource) else { throw FormatError.invalid("ressource d’image") }
            var normalized: Rect?
            if let crop {
                let c = Rect(x: crop.x, y: crop.y, width: crop.w, height: crop.h)
                try require([c.x, c.y, c.width, c.height].allSatisfy { $0.isFinite && $0 >= 0 && $0 <= 1 } && c.width > 0 && c.height > 0, "recadrage")
                normalized = c
            }
            return .image(ImageElement(id: uuid, frame: r, rotation: angle, resource: resource, crop: normalized))
        case "text":
            let body = text ?? ""
            try require(body.count <= TextElement.maxLength, "texte trop long")
            let size = fontSize ?? 16
            try require(size.isFinite && (4...400).contains(size), "taille de police")
            guard let rgba = RGBA(hex: color ?? "#1D2A44") else { throw FormatError.invalid("couleur du texte") }
            var background: RGBA?
            if let fill {
                guard let f = RGBA(hex: fill) else { throw FormatError.invalid("fond de la note") }
                background = f
            }
            return .text(TextElement(
                id: uuid, frame: r, rotation: angle, text: body,
                font: FontFamily(rawValue: font ?? "") ?? .system, fontSize: size, color: rgba,
                bold: bold ?? false, italic: italic ?? false, underline: underline ?? false,
                alignment: TextAlignment(rawValue: alignment ?? "") ?? .left, fill: background
            ))
        case "tape":
            guard let rgba = RGBA(hex: color ?? "") else { throw FormatError.invalid("couleur du ruban") }
            return .tape(TapeElement(id: uuid, frame: r, color: rgba, revealed: revealed ?? false))
        default:
            throw FormatError.invalid("type d’élément inconnu")
        }
    }
}
