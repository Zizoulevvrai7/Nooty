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
        XCTAssertTrue(app.staticTexts["1 sur 1"].exists, "l’indicateur de page doit afficher « 1 sur 1 »")
        capture("04-editeur-stylo")

        for (tool, name) in [("Formes", "05-outil-formes"), ("Gomme", "06-outil-gomme"), ("Texte", "07-outil-texte"), ("Ruban", "08-outil-ruban")] {
            if tapIfPresent(app.buttons[tool]) {
                sleep(1)
                capture(name)
            }
        }

        // Zone de texte : toucher la page avec l'outil Texte.
        if tapIfPresent(app.buttons["Texte"]) {
            app.coordinate(withNormalizedOffset: CGVector(dx: 0.4, dy: 0.45)).tap()
            sleep(1)
            app.typeText("Bornage : délimitation des propriétés")
            sleep(1)
            capture("09-zone-de-texte")
            if tapIfPresent(app.buttons["Terminé"], timeout: 2) || tapIfPresent(app.buttons["Done"], timeout: 2) {}
        }

        if tapIfPresent(app.buttons["Ajouter une page"]) {
            sleep(1)
            capture("10-menu-ajouter-page")
            _ = tapIfPresent(app.buttons["Page vierge après"])
            sleep(1)
        }

        if tapIfPresent(app.buttons["Pages"]) {
            sleep(2)
            capture("11-panneau-pages")
            _ = tapIfPresent(app.buttons["Fermer"])
            sleep(1)
        }

        if tapIfPresent(app.buttons["Insérer"]) {
            sleep(1)
            capture("12-menu-inserer")
            app.coordinate(withNormalizedOffset: CGVector(dx: 0.1, dy: 0.9)).tap()
        }

        if tapIfPresent(app.buttons["Enregistrements"]) {
            sleep(1)
            capture("13-audio")
            _ = tapIfPresent(app.buttons["Fermer"])
        }

        if tapIfPresent(app.buttons["Options"]) {
            sleep(1)
            capture("14-menu-options")
            app.coordinate(withNormalizedOffset: CGVector(dx: 0.1, dy: 0.9)).tap()
        }

        app.navigationBars.buttons.element(boundBy: 0).tap()
        XCTAssertTrue(app.buttons["Nouveau"].waitForExistence(timeout: 10))
        sleep(1)
        capture("15-bibliotheque")

        if tapIfPresent(app.buttons["Réglages"]) {
            sleep(1)
            capture("16-reglages")
        }
    }
}
