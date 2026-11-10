import NootyCore
import PencilKit
import UIKit

enum ToolKind: String, Codable {
    case pen, highlighter, eraser, lasso
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

    var title: String {
        switch self {
        case .ball: return L("pen.ball")
        case .fountain: return L("pen.fountain")
        case .brush: return L("pen.brush")
        }
    }

    var symbol: String {
        switch self {
        case .ball: return "pencil"
        case .fountain: return "pencil.tip"
        case .brush: return "paintbrush.pointed"
        }
    }
}

enum EraserMode: String, Codable {
    /// Efface le trait entier touché.
    case stroke
    /// Efface seulement la partie touchée.
    case precise
}

/// Réglages des outils, conservés d'une session à l'autre.
struct ToolState: Codable, Equatable {
    var kind: ToolKind = .pen
    var penStyle: PenStyle = .ball
    var penWidthIndex = 1
    var penColorIndex = 0
    var penColors = ["#111111", "#1D2A44", "#C62828", "#2E7D32", "#1565C0"]
    var highlighterWidthIndex = 1
    var highlighterColorIndex = 0
    var highlighterColors = ["#FFE14D", "#7CE38B", "#7CC8FF", "#FF9EC4", "#FFB45C"]
    var eraserMode: EraserMode = .stroke
    var eraserSizeIndex = 1

    static let widthCount = 3
    /// Épaisseurs relatives à l'épaisseur par défaut de chaque encre.
    private static let penFactors: [CGFloat] = [0.45, 0.8, 1.5]
    private static let highlighterFactors: [CGFloat] = [0.6, 1, 1.7]
    static let eraserSizes: [CGFloat] = [8, 18, 36]

    private static let key = "nooty.toolState.v1"

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
        let defaults = ToolState()
        func clampIndex(_ i: Int, _ count: Int) -> Int { min(max(0, i), count - 1) }
        if penColors.count != defaults.penColors.count || penColors.contains(where: { RGBA(hex: $0) == nil }) { penColors = defaults.penColors }
        if highlighterColors.count != defaults.highlighterColors.count || highlighterColors.contains(where: { RGBA(hex: $0) == nil }) {
            highlighterColors = defaults.highlighterColors
        }
        penWidthIndex = clampIndex(penWidthIndex, Self.widthCount)
        highlighterWidthIndex = clampIndex(highlighterWidthIndex, Self.widthCount)
        eraserSizeIndex = clampIndex(eraserSizeIndex, Self.eraserSizes.count)
        penColorIndex = clampIndex(penColorIndex, penColors.count)
        highlighterColorIndex = clampIndex(highlighterColorIndex, highlighterColors.count)
    }

    // MARK: - Accès selon l'outil courant

    var showsInkOptions: Bool { kind == .pen || kind == .highlighter }

    var colors: [String] { kind == .highlighter ? highlighterColors : penColors }

    var colorIndex: Int {
        get { kind == .highlighter ? highlighterColorIndex : penColorIndex }
        set { if kind == .highlighter { highlighterColorIndex = newValue } else { penColorIndex = newValue } }
    }

    var widthIndex: Int {
        get { kind == .highlighter ? highlighterWidthIndex : penWidthIndex }
        set { if kind == .highlighter { highlighterWidthIndex = newValue } else { penWidthIndex = newValue } }
    }

    mutating func setColor(_ hex: String, at index: Int) {
        if kind == .highlighter { highlighterColors[index] = hex } else { penColors[index] = hex }
    }

    static func color(_ hex: String) -> UIColor {
        RGBA(hex: hex).map(InkConverter.uiColor) ?? .black
    }

    static func width(for type: PKInkingTool.InkType, factor: CGFloat) -> CGFloat {
        let range = type.validWidthRange
        return min(range.upperBound, max(range.lowerBound, type.defaultWidth * factor))
    }

    /// Outil du moteur d'encre correspondant aux réglages.
    var pkTool: PKTool {
        switch kind {
        case .pen:
            let type = penStyle.inkType
            return PKInkingTool(type, color: Self.color(penColors[penColorIndex]), width: Self.width(for: type, factor: Self.penFactors[penWidthIndex]))
        case .highlighter:
            return PKInkingTool(
                .marker, color: Self.color(highlighterColors[highlighterColorIndex]),
                width: Self.width(for: .marker, factor: Self.highlighterFactors[highlighterWidthIndex])
            )
        case .eraser:
            return eraserMode == .stroke ? PKEraserTool(.vector) : PKEraserTool(.bitmap, width: Self.eraserSizes[eraserSizeIndex])
        case .lasso:
            return PKLassoTool()
        }
    }
}
