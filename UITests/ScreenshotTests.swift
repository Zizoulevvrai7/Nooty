import XCTest

/// Parcourt les écrans principaux et enregistre des captures, pour un contrôle visuel sans appareil.
final class ScreenshotTests: XCTestCase {
    private let folder = URL(fileURLWithPath: "/tmp/nooty-captures")

    private func capture(_ name: String) {
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try? XCUIScreen.main.screenshot().pngRepresentation.write(to: folder.appendingPathComponent("\(name).png"))
    }

    func testMainScreens() {
        continueAfterFailure = true
        let app = XCUIApplication()
        app.launch()
        XCTAssertTrue(app.buttons["Nouveau"].waitForExistence(timeout: 30))
        capture("1-bibliotheque-vide")

        app.buttons["Nouveau"].tap()
        XCTAssertTrue(app.buttons["Bloc-notes"].waitForExistence(timeout: 10))
        app.buttons["Bloc-notes"].tap()
        XCTAssertTrue(app.buttons["Créer"].waitForExistence(timeout: 10))
        capture("2-nouveau-bloc-notes")

        app.buttons["Créer"].tap()
        XCTAssertTrue(app.buttons["Stylo"].waitForExistence(timeout: 20))
        sleep(1)
        let position = app.staticTexts["1 sur 1"]
        XCTAssertTrue(position.exists, "l’indicateur de page doit afficher « 1 sur 1 »")
        XCTAssertGreaterThan(position.frame.width, 30)
        capture("3-editeur-stylo")

        app.buttons["Gomme"].tap()
        sleep(1)
        capture("4-editeur-gomme")

        app.navigationBars.buttons.element(boundBy: 0).tap()
        XCTAssertTrue(app.buttons["Nouveau"].waitForExistence(timeout: 10))
        sleep(1)
        capture("5-bibliotheque")
    }
}
