import Foundation

/// Constantes du format documentaire natif.
public enum NootyFormat {
    /// Version du schéma. Toute évolution incompatible l'incrémente et ajoute une migration.
    public static let schemaVersion = 1
    public static let pageFormat = "nooty.page"
}

/// Point d'un trait, en points typographiques (1/72 pouce), repère de la page.
/// Les champs suivent ce que le matériel fournit ; sans capteur, les valeurs neutres sont conservées.
public struct InkPoint: Equatable, Sendable {
    public var x: Double
    public var y: Double
    /// Secondes écoulées depuis `Stroke.createdAt`.
    public var timeOffset: Double
    public var width: Double
    public var height: Double
    public var opacity: Double
    public var force: Double
    /// Orientation du stylet, en radians.
    public var azimuth: Double
    /// Inclinaison du stylet par rapport à l'écran, en radians (π/2 = vertical).
    public var altitude: Double
    public var secondaryScale: Double

    /// Nombre de composantes par point dans le format d'échange.
    public static let componentCount = 10

    public init(
        x: Double, y: Double, timeOffset: Double = 0, width: Double = 2, height: Double = 2,
        opacity: Double = 1, force: Double = 1, azimuth: Double = 0, altitude: Double = .pi / 2,
        secondaryScale: Double = 1
    ) {
        self.x = x
        self.y = y
        self.timeOffset = timeOffset
        self.width = width
        self.height = height
        self.opacity = opacity
        self.force = force
        self.azimuth = azimuth
        self.altitude = altitude
        self.secondaryScale = secondaryScale
    }

    var components: [Double] {
        [x, y, timeOffset, width, height, opacity, force, azimuth, altitude, secondaryScale]
    }

    init(components c: [Double], at o: Int) {
        self.init(
            x: c[o], y: c[o + 1], timeOffset: c[o + 2], width: c[o + 3], height: c[o + 4],
            opacity: c[o + 5], force: c[o + 6], azimuth: c[o + 7], altitude: c[o + 8],
            secondaryScale: c[o + 9]
        )
    }
}

/// Type d'outil d'encre, indépendant de toute bibliothèque de rendu.
public enum InkTool: String, CaseIterable, Sendable {
    case pen, pencil, marker, monoline, fountainPen, watercolor, crayon
}

/// Couleur sRGB, composantes entre 0 et 1.
public struct RGBA: Equatable, Sendable {
    public var r: Double
    public var g: Double
    public var b: Double
    public var a: Double

    public init(r: Double, g: Double, b: Double, a: Double = 1) {
        func clamp(_ v: Double) -> Double { v.isFinite ? min(max(v, 0), 1) : 0 }
        self.r = clamp(r)
        self.g = clamp(g)
        self.b = clamp(b)
        self.a = clamp(a)
    }

    /// Lit `#RRGGBB` ou `#RRGGBBAA`.
    public init?(hex: String) {
        guard hex.hasPrefix("#") else { return nil }
        let body = hex.dropFirst()
        guard body.count == 6 || body.count == 8, body.allSatisfy(\.isHexDigit),
              let v = UInt32(body, radix: 16) else { return nil }
        func ch(_ shift: UInt32) -> Double { Double((v >> shift) & 0xFF) / 255 }
        if body.count == 6 {
            self.init(r: ch(16), g: ch(8), b: ch(0), a: 1)
        } else {
            self.init(r: ch(24), g: ch(16), b: ch(8), a: ch(0))
        }
    }

    /// Écrit `#RRGGBBAA`.
    public var hex: String {
        func ch(_ v: Double) -> Int { Int((v * 255).rounded()) }
        return String(format: "#%02X%02X%02X%02X", ch(r), ch(g), ch(b), ch(a))
    }

    public static let ink = RGBA(r: 0x1D / 255, g: 0x2A / 255, b: 0x44 / 255)
}

/// Matrice affine, même convention que CGAffineTransform :
/// x' = a·x + c·y + tx ; y' = b·x + d·y + ty.
public struct AffineMatrix: Equatable, Sendable {
    public var a, b, c, d, tx, ty: Double

    public init(a: Double, b: Double, c: Double, d: Double, tx: Double, ty: Double) {
        self.a = a
        self.b = b
        self.c = c
        self.d = d
        self.tx = tx
        self.ty = ty
    }

    public static let identity = AffineMatrix(a: 1, b: 0, c: 0, d: 1, tx: 0, ty: 0)

    public static func translation(_ x: Double, _ y: Double) -> AffineMatrix {
        AffineMatrix(a: 1, b: 0, c: 0, d: 1, tx: x, ty: y)
    }

    public static func scale(_ sx: Double, _ sy: Double) -> AffineMatrix {
        AffineMatrix(a: sx, b: 0, c: 0, d: sy, tx: 0, ty: 0)
    }

    public static func rotation(_ angle: Double) -> AffineMatrix {
        AffineMatrix(a: cos(angle), b: sin(angle), c: -sin(angle), d: cos(angle), tx: 0, ty: 0)
    }

    public var isIdentity: Bool { self == .identity }

    public var values: [Double] { [a, b, c, d, tx, ty] }

    public func apply(_ x: Double, _ y: Double) -> (x: Double, y: Double) {
        (a * x + c * y + tx, b * x + d * y + ty)
    }

    /// Applique `self` puis `m`.
    public func concatenating(_ m: AffineMatrix) -> AffineMatrix {
        AffineMatrix(
            a: a * m.a + b * m.c,
            b: a * m.b + b * m.d,
            c: c * m.a + d * m.c,
            d: c * m.b + d * m.d,
            tx: tx * m.a + ty * m.c + m.tx,
            ty: tx * m.b + ty * m.d + m.ty
        )
    }

    public var inverted: AffineMatrix? {
        let det = a * d - b * c
        guard det.isFinite, abs(det) > 1e-12 else { return nil }
        return AffineMatrix(
            a: d / det, b: -b / det, c: -c / det, d: a / det,
            tx: (c * ty - d * tx) / det, ty: (b * tx - a * ty) / det
        )
    }
}

public struct BBox: Equatable, Sendable {
    public var minX, minY, maxX, maxY: Double

    public init(minX: Double, minY: Double, maxX: Double, maxY: Double) {
        self.minX = minX
        self.minY = minY
        self.maxX = maxX
        self.maxY = maxY
    }

    public func union(_ o: BBox) -> BBox {
        BBox(minX: min(minX, o.minX), minY: min(minY, o.minY), maxX: max(maxX, o.maxX), maxY: max(maxY, o.maxY))
    }

    public func intersects(_ o: BBox) -> Bool {
        minX <= o.maxX && maxX >= o.minX && minY <= o.maxY && maxY >= o.minY
    }
}

/// Élément de chemin vectoriel (masque d'un trait partiellement gommé).
public enum PathElement: Equatable, Sendable {
    case move(Double, Double)
    case line(Double, Double)
    case quad(Double, Double, Double, Double)
    case cubic(Double, Double, Double, Double, Double, Double)
    case close
}

public struct Stroke: Identifiable, Equatable, Sendable {
    public var id: UUID
    public var tool: InkTool
    public var color: RGBA
    public var points: [InkPoint]
    public var transform: AffineMatrix
    /// Zone visible du trait, en repère du trait ; nil si le trait est entièrement visible.
    public var mask: [PathElement]?
    /// Horodatage absolu du premier point, en millisecondes depuis 1970.
    public var createdAt: Double
    /// Graine des variations de rendu (texture du crayon, etc.).
    public var randomSeed: UInt32

    public init(
        id: UUID = UUID(), tool: InkTool, color: RGBA, points: [InkPoint],
        transform: AffineMatrix = .identity, mask: [PathElement]? = nil,
        createdAt: Double, randomSeed: UInt32 = 0
    ) {
        self.id = id
        self.tool = tool
        self.color = color
        self.points = points
        self.transform = transform
        self.mask = mask
        self.createdAt = createdAt
        self.randomSeed = randomSeed
    }

    /// Boîte englobante en repère page, épaisseur et transformation comprises.
    public var bounds: BBox? {
        guard !points.isEmpty else { return nil }
        var minX = Double.infinity, minY = Double.infinity, maxX = -Double.infinity, maxY = -Double.infinity
        for p in points {
            let r = max(p.width, p.height) / 2
            minX = min(minX, p.x - r)
            minY = min(minY, p.y - r)
            maxX = max(maxX, p.x + r)
            maxY = max(maxY, p.y + r)
        }
        if transform.isIdentity { return BBox(minX: minX, minY: minY, maxX: maxX, maxY: maxY) }
        let corners = [(minX, minY), (maxX, minY), (minX, maxY), (maxX, maxY)].map { transform.apply($0.0, $0.1) }
        return BBox(
            minX: corners.map(\.x).min()!, minY: corners.map(\.y).min()!,
            maxX: corners.map(\.x).max()!, maxY: corners.map(\.y).max()!
        )
    }
}

public enum BackgroundKind: String, CaseIterable, Sendable {
    case blank, ruled, grid, dots
}

public struct Background: Equatable, Sendable {
    public var kind: BackgroundKind
    public var color: RGBA
    public var lineColor: RGBA
    /// Espacement des lignes, en points typographiques.
    public var spacing: Double

    public init(kind: BackgroundKind, color: RGBA, lineColor: RGBA, spacing: Double) {
        self.kind = kind
        self.color = color
        self.lineColor = lineColor
        self.spacing = spacing
    }

    public static let millimeter = 72 / 25.4

    public static func standard(_ kind: BackgroundKind) -> Background {
        Background(
            kind: kind,
            color: RGBA(r: 1, g: 0xFD / 255, b: 0xF8 / 255),
            lineColor: RGBA(r: 0xC9 / 255, g: 0xD3 / 255, b: 0xE0 / 255),
            spacing: (kind == .ruled ? 7 : 5) * millimeter
        )
    }
}

public struct Page: Identifiable, Equatable, Sendable {
    public var id: UUID
    /// Dimensions en points typographiques.
    public var width: Double
    public var height: Double
    public var background: Background
    /// Traits dans l'ordre d'affichage (le dernier est au-dessus).
    public var strokes: [Stroke]
    /// Dernière modification, en millisecondes depuis 1970.
    public var updatedAt: Double

    public init(id: UUID = UUID(), width: Double, height: Double, background: Background, strokes: [Stroke] = [], updatedAt: Double) {
        self.id = id
        self.width = width
        self.height = height
        self.background = background
        self.strokes = strokes
        self.updatedAt = updatedAt
    }

    public static let a4Width = 595.28
    public static let a4Height = 841.89

    public static func a4(id: UUID = UUID(), updatedAt: Double) -> Page {
        Page(id: id, width: a4Width, height: a4Height, background: .standard(.ruled), updatedAt: updatedAt)
    }
}

/// Mesures d'un trait pour le diagnostic du stylet.
public struct StrokeStats: Equatable, Sendable {
    public var pointCount: Int
    public var forceMin: Double
    public var forceMax: Double
    /// Degrés.
    public var altitudeMin: Double
    public var altitudeMax: Double
    public var durationSeconds: Double

    public init?(_ s: Stroke) {
        guard let first = s.points.first else { return nil }
        pointCount = s.points.count
        forceMin = first.force
        forceMax = first.force
        altitudeMin = first.altitude
        altitudeMax = first.altitude
        var maxT = first.timeOffset
        for p in s.points {
            forceMin = min(forceMin, p.force)
            forceMax = max(forceMax, p.force)
            altitudeMin = min(altitudeMin, p.altitude)
            altitudeMax = max(altitudeMax, p.altitude)
            maxT = max(maxT, p.timeOffset)
        }
        altitudeMin *= 180 / .pi
        altitudeMax *= 180 / .pi
        durationSeconds = maxT
    }
}
