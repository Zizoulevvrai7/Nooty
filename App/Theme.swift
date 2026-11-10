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
