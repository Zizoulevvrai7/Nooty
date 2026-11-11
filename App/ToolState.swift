import NootyCore
import PencilKit
import UIKit

enum ToolKind: String, Codable, CaseIterable {
    case pen, pencil, highlighter, eraser, lasso, shape, text, tape, laser

    /// Outils qui écrivent avec le moteur d'encre ; les autres sont gérés par Nooty.
    var usesInk: Bool { [.pen, .pencil, .highlighter, .eraser, .lasso].contains(self) }

    var symbol: String {
        switch self {
        case .pen: return "pencil"
        case .pencil: return "pencil.and.scribble"
        case .highlighter: return "highlighter"
        case .eraser: return "eraser"
        case .lasso: return "lasso"
        case .shape: return "square.on.circle"
        case .text: return "textformat"
        case .tape: return "rectangle.fill.on.rectangle.fill"
        case .laser: return "cursorarrow.rays"
        }
    }

    var title: String { L("tool.\(rawValue)") }
}

/// Types de stylo proposés, chacun associé à une encre du moteur.
enum PenStyle: String, Codable, CaseIterable {
    /// Trait régulier, insensible à la pression.
    case ball
    /// Trait qui s'élargit avec la pression et l'inclinaison.
    case fountain
    /// Trait souple, sensible à la pression.
    case brush

    var inkType: PKInkingTool.InkType {
        switch self {
        case .ball: return .monoline
        case .fountain: return .fountainPen
        case .brush: return .pen
        }
    }

    var title: String { L("pen.\(rawValue)") }

    var symbol: String {
        switch self {
        case .ball: return "pencil"
        case .fountain: return "pencil.tip"
        case .brush: return "paintbrush.pointed"
        }
    }
}

enum EraserMode: String, Codable, CaseIterable {
    /// Efface seulement ce qui est touché, avec un diamètre fixe.
    case precise
    /// Efface ce qui est touché, diamètre selon la pression.
    case standard
    /// Efface le trait entier touché.
    case stroke

    var title: String { L("eraser.\(rawValue)") }
}

/// Réglages des outils, conservés d'une session à l'autre.
struct ToolState: Codable, Equatable {
    var kind: ToolKind = .pen
    var penStyle: PenStyle = .ball
    var penWidthIndex = 1
    var pencilWidthIndex = 1
    var highlighterWidthIndex = 1
    /// Facteurs d'épaisseur des trois préréglages de chaque outil, modifiables.
    var penWidths: [Double] = [0.45, 0.8, 1.5]
    var pencilWidths: [Double] = [0.6, 1, 1.8]
    var highlighterWidths: [Double] = [0.6, 1, 1.7]
    var penColorIndex = 0
    var penColors = ["#111111", "#1D2A44", "#C62828", "#2E7D32", "#1565C0"]
    var highlighterColorIndex = 0
    var highlighterColors = ["#FFE14D", "#7CE38B", "#7CC8FF", "#FF9EC4", "#FFB45C"]
    var tapeColorIndex = 0
    var tapeColors = ["#F2B33D", "#7CC8FF", "#9BE3A2", "#F59AC0", "#B9A7F2"]
    var eraserMode: EraserMode = .stroke
    var eraserSizeIndex = 1
    var shape = ShapeKind.rectangle.rawValue
    /// Dessiner puis maintenir le stylet redresse la forme.
    var holdToShape = true

    static let widthCount = 3
    static let eraserSizes: [CGFloat] = [6, 14, 30]
    static let widthRange: ClosedRange<Double> = 0.15...4

    private static let key = "nooty.toolState.v2"

    static func load() -> ToolState {
        guard let data = UserDefaults.standard.data(forKey: key),
              var state = try? JSONDecoder().decode(ToolState.self, from: data) else { return ToolState() }
        state.sanitize()
        return state
    }

    func save() {
        if let data = try? JSONEncoder().encode(self) { UserDefaults.standard.set(data, forKey: Self.key) }
    }

    /// Remet dans les bornes des réglages qui auraient été altérés.
    mutating func sanitize() {
        let d = ToolState()
        func clamp(_ i: Int, _ count: Int) -> Int { min(max(0, i), count - 1) }
        func colors(_ list: [String], _ fallback: [String]) -> [String] {
            list.count == fallback.count && list.allSatisfy { RGBA(hex: $0) != nil } ? list : fallback
        }
        func widths(_ list: [Double], _ fallback: [Double]) -> [Double] {
            list.count == Self.widthCount && list.allSatisfy { Self.widthRange.contains($0) } ? list : fallback
        }
        penColors = colors(penColors, d.penColors)
        highlighterColors = colors(highlighterColors, d.highlighterColors)
        tapeColors = colors(tapeColors, d.tapeColors)
        penWidths = widths(penWidths, d.penWidths)
        pencilWidths = widths(pencilWidths, d.pencilWidths)
        highlighterWidths = widths(highlighterWidths, d.highlighterWidths)
        penWidthIndex = clamp(penWidthIndex, Self.widthCount)
        pencilWidthIndex = clamp(pencilWidthIndex, Self.widthCount)
        highlighterWidthIndex = clamp(highlighterWidthIndex, Self.widthCount)
        eraserSizeIndex = clamp(eraserSizeIndex, Self.eraserSizes.count)
        penColorIndex = clamp(penColorIndex, penColors.count)
        highlighterColorIndex = clamp(highlighterColorIndex, highlighterColors.count)
        tapeColorIndex = clamp(tapeColorIndex, tapeColors.count)
        if ShapeKind(rawValue: shape) == nil { shape = ShapeKind.rectangle.rawValue }
    }

    // MARK: - Accès selon l'outil courant

    var shapeKind: ShapeKind {
        get { ShapeKind(rawValue: shape) ?? .rectangle }
        set { shape = newValue.rawValue }
    }

    var hasWidths: Bool { [.pen, .pencil, .highlighter, .shape].contains(kind) }
    var hasColors: Bool { [.pen, .pencil, .highlighter, .shape, .text, .tape].contains(kind) }

    var colors: [String] {
        switch kind {
        case .highlighter: return highlighterColors
        case .tape: return tapeColors
        default: return penColors
        }
    }

    var colorIndex: Int {
        get {
            switch kind {
            case .highlighter: return highlighterColorIndex
            case .tape: return tapeColorIndex
            default: return penColorIndex
            }
        }
        set {
            switch kind {
            case .highlighter: highlighterColorIndex = newValue
            case .tape: tapeColorIndex = newValue
            default: penColorIndex = newValue
            }
        }
    }

    mutating func setColor(_ hex: String, at index: Int) {
        switch kind {
        case .highlighter: highlighterColors[index] = hex
        case .tape: tapeColors[index] = hex
        default: penColors[index] = hex
        }
    }

    var widths: [Double] {
        switch kind {
        case .pencil: return pencilWidths
        case .highlighter: return highlighterWidths
        default: return penWidths
        }
    }

    var widthIndex: Int {
        get {
            switch kind {
            case .pencil: return pencilWidthIndex
            case .highlighter: return highlighterWidthIndex
            default: return penWidthIndex
            }
        }
        set {
            switch kind {
            case .pencil: pencilWidthIndex = newValue
            case .highlighter: highlighterWidthIndex = newValue
            default: penWidthIndex = newValue
            }
        }
    }

    mutating func setWidth(_ factor: Double, at index: Int) {
        let v = min(Self.widthRange.upperBound, max(Self.widthRange.lowerBound, factor))
        switch kind {
        case .pencil: pencilWidths[index] = v
        case .highlighter: highlighterWidths[index] = v
        default: penWidths[index] = v
        }
    }

    static func color(_ hex: String) -> UIColor {
        RGBA(hex: hex).map(InkConverter.uiColor) ?? .black
    }

    var currentColor: UIColor { Self.color(colors[colorIndex]) }
    var currentRGBA: RGBA { RGBA(hex: colors[colorIndex]) ?? .ink }

    static func width(for type: PKInkingTool.InkType, factor: Double) -> CGFloat {
        let range = type.validWidthRange
        return min(range.upperBound, max(range.lowerBound, type.defaultWidth * CGFloat(factor)))
    }

    /// Épaisseur des formes, en points de page.
    var shapeLineWidth: CGFloat { Self.width(for: .monoline, factor: penWidths[penWidthIndex]) }

    /// Outil du moteur d'encre correspondant aux réglages.
    var pkTool: PKTool {
        switch kind {
        case .pen, .shape, .text, .tape, .laser:
            let type = penStyle.inkType
            return PKInkingTool(type, color: Self.color(penColors[penColorIndex]), width: Self.width(for: type, factor: penWidths[penWidthIndex]))
        case .pencil:
            return PKInkingTool(.pencil, color: Self.color(penColors[penColorIndex]), width: Self.width(for: .pencil, factor: pencilWidths[pencilWidthIndex]))
        case .highlighter:
            return PKInkingTool(
                .marker, color: Self.color(highlighterColors[highlighterColorIndex]),
                width: Self.width(for: .marker, factor: highlighterWidths[highlighterWidthIndex])
            )
        case .eraser:
            switch eraserMode {
            case .stroke: return PKEraserTool(.vector)
            case .standard: return PKEraserTool(.bitmap, width: Self.eraserSizes[eraserSizeIndex] * 1.5)
            case .precise: return PKEraserTool(.fixedWidthBitmap, width: Self.eraserSizes[eraserSizeIndex])
            }
        case .lasso:
            return PKLassoTool()
        }
    }
}

extension ShapeKind {
    var title: String { L("shape.\(rawValue)") }

    var symbol: String {
        switch self {
        case .line: return "line.diagonal"
        case .arrow: return "arrow.up.right"
        case .rectangle: return "rectangle"
        case .ellipse: return "circle"
        case .triangle: return "triangle"
        case .diamond: return "diamond"
        }
    }
}
