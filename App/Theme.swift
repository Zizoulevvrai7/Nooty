import NootyCore
import UIKit

/// Identité visuelle de Nooty : encre bleu nuit, accent corail, papier chaud.
enum Theme {
    private static func dynamic(light: UInt32, dark: UInt32) -> UIColor {
        UIColor { $0.userInterfaceStyle == .dark ? UIColor(hex: dark) : UIColor(hex: light) }
    }

    static let ink = UIColor(hex: 0x1D2A44)
    static let accent = dynamic(light: 0xC2500F, dark: 0xF5A26A)
    static let accentSoft = dynamic(light: 0xFBE4D3, dark: 0x4A3120)
    static let desk = dynamic(light: 0xEBE7DF, dark: 0x15171C)
    static let panel = dynamic(light: 0xFFFDF8, dark: 0x23262D)
    static let hairline = dynamic(light: 0xD8D2C6, dark: 0x3A3F4A)
    static let text = dynamic(light: 0x1D2A44, dark: 0xEEF0F4)
    static let secondaryText = dynamic(light: 0x5D6779, dark: 0xA9B1C0)

    // MARK: Habillage de l'éditeur
    // Graphite et corail : l'éditeur est une trousse sombre posée autour du papier, quel que
    // soit le mode d'apparence ; le papier reste la seule surface claire.

    /// Rangée des onglets, la plus sombre.
    static let chromeDeep = UIColor(hex: 0x17191D)
    /// Barre d'outils principale ; l'onglet actif prend la même teinte.
    static let chrome = UIColor(hex: 0x24272D)
    /// Pastilles flottantes et cartes des menus.
    static let chromeRaised = UIColor(hex: 0x2F333A)
    /// Fond des menus déroulants.
    static let sheet = UIColor(hex: 0x1F2126)
    static let sheetCard = UIColor(hex: 0x2B2E35)
    static let chromeLine = UIColor(hex: 0x3B3F48)
    static let chromeText = UIColor(hex: 0xECEDEF)
    static let chromeMuted = UIColor(hex: 0x9CA2AD)
    /// Corail lumineux, lisible sur le graphite.
    static let coral = UIColor(hex: 0xFF8B52)
    static let coralWash = UIColor(hex: 0xFF8B52).withAlphaComponent(0.2)
    static let danger = UIColor(hex: 0xFF6B5E)
    static let editorDesk = dynamic(light: 0xD6D2CA, dark: 0x111215)

    /// Police arrondie des titres de l'éditeur : la voix de Nooty.
    static func rounded(_ size: CGFloat, _ weight: UIFont.Weight = .semibold, style: UIFont.TextStyle = .body) -> UIFont {
        let base = UIFont.systemFont(ofSize: size, weight: weight)
        let font = base.fontDescriptor.withDesign(.rounded).map { UIFont(descriptor: $0, size: size) } ?? base
        return UIFontMetrics(forTextStyle: style).scaledFont(for: font)
    }

    /// Couleurs proposées à tour de rôle pour les couvertures et les dossiers.
    static let coverColors: [RGBA] = ["#1D2A44", "#C2500F", "#2E7D5B", "#7A4FB5", "#C0396B", "#2F6FB7", "#B58A1B"].compactMap { RGBA(hex: $0) }

    static func style(panel view: UIView, radius: CGFloat = 16) {
        view.backgroundColor = panel
        view.layer.cornerRadius = radius
        view.layer.cornerCurve = .continuous
        view.layer.borderWidth = 1
        view.layer.borderColor = hairline.cgColor
        view.layer.shadowColor = UIColor.black.cgColor
        view.layer.shadowOpacity = 0.12
        view.layer.shadowRadius = 14
        view.layer.shadowOffset = CGSize(width: 0, height: 4)
    }
}

extension UIColor {
    convenience init(hex: UInt32) {
        self.init(
            red: CGFloat((hex >> 16) & 0xFF) / 255, green: CGFloat((hex >> 8) & 0xFF) / 255,
            blue: CGFloat(hex & 0xFF) / 255, alpha: 1
        )
    }
}

func nowMs() -> Double {
    (Date().timeIntervalSince1970 * 1000).rounded()
}
