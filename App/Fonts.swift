import NootyCore
import UIKit

/// Familles de polices proposées pour les zones de texte, rangées par usage.
extension FontFamily {
    enum Group: String, CaseIterable {
        case system, sans, serif, mono, hand, display
        var title: String { L("fontGroup.\(rawValue)") }
    }

    /// Nom de famille iOS ; `nil` pour les quatre polices du système.
    var familyName: String? {
        switch self {
        case .system, .serif, .rounded, .monospaced: return nil
        case .avenir: return "Avenir Next"
        case .futura: return "Futura"
        case .gillSans: return "Gill Sans"
        case .helvetica: return "Helvetica Neue"
        case .optima: return "Optima"
        case .trebuchet: return "Trebuchet MS"
        case .verdana: return "Verdana"
        case .georgia: return "Georgia"
        case .baskerville: return "Baskerville"
        case .palatino: return "Palatino"
        case .didot: return "Didot"
        case .bodoni: return "Bodoni 72"
        case .hoefler: return "Hoefler Text"
        case .charter: return "Charter"
        case .cochin: return "Cochin"
        case .times: return "Times New Roman"
        case .typewriter: return "American Typewriter"
        case .courier: return "Courier New"
        case .menlo: return "Menlo"
        case .chalkboard: return "Chalkboard SE"
        case .markerFelt: return "Marker Felt"
        case .noteworthy: return "Noteworthy"
        case .bradleyHand: return "Bradley Hand"
        case .snellRoundhand: return "Snell Roundhand"
        case .savoye: return "Savoye LET"
        case .zapfino: return "Zapfino"
        case .chalkduster: return "Chalkduster"
        case .rockwell: return "Rockwell"
        case .copperplate: return "Copperplate"
        case .papyrus: return "Papyrus"
        case .party: return "Party LET"
        }
    }

    var group: Group {
        switch self {
        case .system, .serif, .rounded, .monospaced: return .system
        case .avenir, .futura, .gillSans, .helvetica, .optima, .trebuchet, .verdana: return .sans
        case .georgia, .baskerville, .palatino, .didot, .bodoni, .hoefler, .charter, .cochin, .times: return .serif
        case .typewriter, .courier, .menlo: return .mono
        case .chalkboard, .markerFelt, .noteworthy, .bradleyHand, .snellRoundhand, .savoye, .zapfino, .chalkduster: return .hand
        case .rockwell, .copperplate, .papyrus, .party: return .display
        }
    }

    /// Nom affiché : celui de la famille, ou un nom en français pour les polices du système.
    var displayName: String { familyName ?? L("font.\(rawValue)") }

    /// Polices réellement présentes sur l'appareil.
    static var available: [FontFamily] {
        let installed = Set(UIFont.familyNames)
        return allCases.filter { $0.familyName.map(installed.contains) ?? true }
    }

    /// Police à la taille demandée, avec gras et italique si la famille les possède.
    func font(size: CGFloat, bold: Bool = false, italic: Bool = false) -> UIFont {
        var descriptor: UIFontDescriptor
        if let familyName, UIFont.familyNames.contains(familyName) {
            descriptor = UIFontDescriptor(fontAttributes: [.family: familyName])
        } else {
            descriptor = UIFont.systemFont(ofSize: size).fontDescriptor
            switch self {
            case .serif: descriptor = descriptor.withDesign(.serif) ?? descriptor
            case .rounded: descriptor = descriptor.withDesign(.rounded) ?? descriptor
            case .monospaced: descriptor = descriptor.withDesign(.monospaced) ?? descriptor
            default: break
            }
        }
        var traits: UIFontDescriptor.SymbolicTraits = []
        if bold { traits.insert(.traitBold) }
        if italic { traits.insert(.traitItalic) }
        if !traits.isEmpty { descriptor = descriptor.withSymbolicTraits(traits) ?? descriptor }
        return UIFont(descriptor: descriptor, size: size)
    }
}
