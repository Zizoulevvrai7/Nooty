import XCTest

/// Parcourt les écrans principaux et enregistre des captures, pour un contrôle visuel sans appareil.
final class ScreenshotTests: XCTestCase {
    private let folder = URL(fileURLWithPath: "/tmp/nooty-captures")

    private func capture(_ name: String) {
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try? XCUIScreen.main.screenshot().pngRepresentation.write(to: folder.appendingPathComponent("\(name).png"))
    }

    private func tapIfPresent(_ element: XCUIElement, timeout: TimeInterval = 5) -> Bool {
        guard element.waitForExistence(timeout: timeout) else { return false }
        element.tap()
        return true
    }

    /// Ferme une bulle en touchant le bas de l'écran, hors de la bulle.
    private func dismissPopover(_ app: XCUIApplication) {
        app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.97)).tap()
        sleep(1)
    }

    func testMainScreens() {
        continueAfterFailure = true
        let app = XCUIApplication()
        app.launch()
        XCTAssertTrue(app.buttons["Nouveau"].waitForExistence(timeout: 30))
        capture("01-bibliotheque-vide")

        app.buttons["Nouveau"].tap()
        sleep(1)
        capture("02-menu-nouveau")
        XCTAssertTrue(tapIfPresent(app.buttons["Bloc-notes"]))
        XCTAssertTrue(app.buttons["Créer"].waitForExistence(timeout: 10))
        capture("03-nouveau-bloc-notes")

        app.buttons["Créer"].tap()
        XCTAssertTrue(app.buttons["Stylo"].waitForExistence(timeout: 20))
        sleep(1)
        XCTAssertTrue(app.buttons["1 sur 1"].exists, "l’indicateur de page doit afficher « 1 sur 1 »")
        capture("04-editeur-stylo")

        // Toucher l'outil déjà choisi ouvre ses réglages.
        if tapIfPresent(app.buttons["Stylo"]) {
            sleep(1)
            capture("04b-menu-stylo")
            dismissPopover(app)
        }

        for (tool, name) in [("Formes", "05-outil-formes"), ("Gomme", "06-outil-gomme"), ("Texte", "07-outil-texte"), ("Ruban", "08-outil-ruban")] {
            if tapIfPresent(app.buttons[tool]) {
                sleep(1)
                capture(name)
            }
        }
        if tapIfPresent(app.buttons["Gomme"]) {
            _ = tapIfPresent(app.buttons["Gomme"], timeout: 2)
            sleep(1)
            capture("06b-menu-gomme")
            dismissPopover(app)
        }
        if tapIfPresent(app.buttons["Formes"]) {
            if tapIfPresent(app.buttons["Réglages du trait"], timeout: 2) {
                sleep(1)
                capture("05b-menu-formes")
                dismissPopover(app)
            }
        }

        // Zone de texte : toucher la page avec l'outil Texte.
        if tapIfPresent(app.buttons["Texte"]) {
            if tapIfPresent(app.buttons["Police"], timeout: 2) {
                sleep(1)
                capture("07b-menu-polices")
                dismissPopover(app)
            }
            app.coordinate(withNormalizedOffset: CGVector(dx: 0.4, dy: 0.45)).tap()
            sleep(1)
            let field = app.textViews.firstMatch
            if field.exists {
                field.typeText("Bornage : délimitation des propriétés")
            }
            sleep(1)
            capture("09-zone-de-texte")
            if tapIfPresent(app.buttons["Terminé"], timeout: 2) || tapIfPresent(app.buttons["Done"], timeout: 2) {}
        }

        if tapIfPresent(app.buttons["Ajouter une page"]) {
            sleep(1)
            capture("10-menu-ajouter-page")
            if !tapIfPresent(app.buttons["Vierge"], timeout: 2) { dismissPopover(app) }
            sleep(1)
        }

        if tapIfPresent(app.buttons["Pages"]) {
            sleep(2)
            capture("11-panneau-pages")
            _ = tapIfPresent(app.buttons["Fermer"])
            sleep(1)
        }

        for (button, name) in [("Insérer", "12-menu-inserer"), ("Partager et exporter", "13-menu-partager"), ("Options", "14-menu-options")] {
            if tapIfPresent(app.buttons[button]) {
                sleep(1)
                capture(name)
                dismissPopover(app)
            }
        }

        if tapIfPresent(app.buttons["Lecture seule"]) {
            sleep(1)
            capture("14b-lecture-seule")
            _ = tapIfPresent(app.buttons["Lecture seule"])
        }

        _ = tapIfPresent(app.buttons["Bibliothèque"])
        XCTAssertTrue(app.buttons["Nouveau"].waitForExistence(timeout: 10))
        sleep(1)
        capture("15-bibliotheque")

        if tapIfPresent(app.buttons["Réglages"]) {
            sleep(1)
            capture("16-reglages")
        }
    }
}
