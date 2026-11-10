import NootyCore
import PencilKit
import XCTest
@testable import Nooty

final class InkConverterTests: XCTestCase {
    private func sample() -> [Stroke] {
        var strokes = StrokeGenerator.handwriting(count: 30, pageWidth: Page.a4Width, pageHeight: Page.a4Height, seed: 11, createdAt: 1_700_000_000_000)
        strokes[2].transform = AffineMatrix(a: 0.8, b: 0.2, c: -0.2, d: 0.8, tx: 15, ty: -6)
        strokes[4].mask = [.move(0, 0), .line(60, 0), .quad(70, 10, 60, 40), .cubic(40, 60, 10, 60, 0, 40), .close]
        strokes[6].tool = .marker
        strokes[6].color = RGBA(hex: "#F5C51880")!
        return strokes
    }

    /// Égalité à la précision du fichier (Float32) de tous les champs, sauf l'inclinaison :
    /// PencilKit la stocke avec une précision réduite et elle oscille d'environ 2·10⁻⁵ rad (0,001°).
    private func assertSamePoints(_ a: [InkPoint], _ b: [InkPoint], file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertEqual(a.count, b.count, file: file, line: line)
        func f32(_ p: InkPoint) -> [Float32] {
            [p.x, p.y, p.timeOffset, p.width, p.height, p.opacity, p.force, p.azimuth, p.secondaryScale].map { Float32($0) }
        }
        for (p, q) in zip(a, b) {
            XCTAssertEqual(f32(p), f32(q), file: file, line: line)
            XCTAssertEqual(p.altitude, q.altitude, accuracy: 1e-4, file: file, line: line)
        }
    }

    func testToolMappingRoundTrip() {
        for tool in InkTool.allCases {
            XCTAssertEqual(InkConverter.tool(InkConverter.inkType(tool)), tool)
        }
    }

    /// PencilKit normalise certaines valeurs à la création d'un trait (pression arrondie,
    /// courbes du masque converties en segments). Ce qui compte : une fois normalisé, un trait
    /// traverse indéfiniment PencilKit et le fichier sans aucune dérive.
    func testConversionIsStableAfterPencilKitNormalisation() throws {
        for original in sample() {
            let once = InkConverter.stroke(from: InkConverter.pkStroke(original), id: original.id)
            let twice = InkConverter.stroke(from: InkConverter.pkStroke(once), id: original.id)
            assertSamePoints(twice.points, once.points)
            XCTAssertEqual(twice.mask, once.mask)
            XCTAssertEqual(twice.transform, once.transform)
            XCTAssertEqual(twice.identityKey, once.identityKey)

            // Passage par le fichier puis retour dans PencilKit : identique au contenu du fichier.
            var page = Page.a4(updatedAt: 0)
            page.strokes = [once]
            let stored = try PageCodec.decode(try PageCodec.encode(page)).strokes[0]
            let reloaded = InkConverter.stroke(from: InkConverter.pkStroke(stored), id: stored.id)
            assertSamePoints(reloaded.points, stored.points)
            XCTAssertEqual(reloaded.mask, stored.mask)
            XCTAssertEqual(reloaded.identityKey, once.identityKey)
        }
    }

    /// Simule cinq fermetures et réouvertures : aucune valeur ne doit dériver.
    func testRepeatedSaveAndReloadDoesNotDrift() throws {
        var page = Page.a4(updatedAt: 0)
        page.strokes = sample().map { InkConverter.stroke(from: InkConverter.pkStroke($0), id: $0.id) }
        let first = try PageCodec.decode(try PageCodec.encode(page))
        var current = first
        for _ in 0..<5 {
            let canvas = InkConverter.drawing(current.strokes)
            current.strokes = zip(canvas.strokes, current.strokes).map { InkConverter.stroke(from: $0, id: $1.id) }
            current = try PageCodec.decode(try PageCodec.encode(current))
        }
        XCTAssertEqual(current.strokes.map(\.id), first.strokes.map(\.id))
        for (s, o) in zip(current.strokes, first.strokes) {
            XCTAssertEqual(s.identityKey, o.identityKey)
            assertSamePoints(s.points, o.points)
        }
    }

    /// La normalisation de PencilKit reste invisible : écarts mesurés par rapport aux valeurs fournies.
    func testPencilKitNormalisationStaysNegligible() {
        for original in sample() {
            let once = InkConverter.stroke(from: InkConverter.pkStroke(original), id: original.id)
            XCTAssertEqual(once.tool, original.tool)
            XCTAssertEqual(once.transform, original.transform)
            XCTAssertEqual(once.createdAt, original.createdAt)
            XCTAssertEqual(once.randomSeed, original.randomSeed)
            XCTAssertEqual(once.color.r, original.color.r, accuracy: 0.004)
            XCTAssertEqual(once.color.a, original.color.a, accuracy: 0.004)
            XCTAssertEqual(once.points.count, original.points.count)
            for (p, q) in zip(once.points, original.points) {
                XCTAssertEqual(p.x, q.x, accuracy: 0.001)
                XCTAssertEqual(p.y, q.y, accuracy: 0.001)
                XCTAssertEqual(p.timeOffset, q.timeOffset, accuracy: 0.001)
                XCTAssertEqual(p.width, q.width, accuracy: 0.001)
                XCTAssertEqual(p.force, q.force, accuracy: 0.002)
                XCTAssertEqual(p.opacity, q.opacity, accuracy: 0.001)
                XCTAssertEqual(p.azimuth, q.azimuth, accuracy: 0.001)
                XCTAssertEqual(p.altitude, q.altitude, accuracy: 0.001)
            }
            if let mask = original.mask {
                XCTAssertNotNil(once.mask)
                XCTAssertFalse(once.mask!.isEmpty)
                XCTAssertEqual(once.mask!.count >= mask.count, true)
            }
        }
    }

    func testFullChainCanvasFileCanvasKeepsTheDrawing() throws {
        let drawing = InkConverter.drawing(sample())
        let page = Page(width: Page.a4Width, height: Page.a4Height, background: .standard(.ruled),
                        strokes: drawing.strokes.map { InkConverter.stroke(from: $0) }, updatedAt: 0)
        let reloaded = InkConverter.drawing(try PageCodec.decode(try PageCodec.encode(page)).strokes)
        XCTAssertEqual(reloaded.strokes.count, drawing.strokes.count)
        let a = drawing.bounds, b = reloaded.bounds
        XCTAssertEqual(a.minX, b.minX, accuracy: 0.05)
        XCTAssertEqual(a.minY, b.minY, accuracy: 0.05)
        XCTAssertEqual(a.maxX, b.maxX, accuracy: 0.05)
        XCTAssertEqual(a.maxY, b.maxY, accuracy: 0.05)
    }

    func testStoreSavesReloadsAndKeepsIDs() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }

        let store = PageStore(directory: dir)
        XCTAssertNil(try store.load())
        var drawing = InkConverter.drawing(sample())
        let first = try store.save(drawing: drawing, pageID: UUID(), size: CGSize(width: 595, height: 842), background: .standard(.dots))

        let reopened = PageStore(directory: dir)
        let loaded = try XCTUnwrap(try reopened.load())
        XCTAssertEqual(loaded.background.kind, .dots)
        XCTAssertEqual(loaded.strokes.map(\.id), first.page.strokes.map(\.id))

        // Un trait déplacé garde son identifiant ; un trait ajouté en reçoit un nouveau.
        drawing = InkConverter.drawing(loaded.strokes)
        drawing.strokes[0].transform = CGAffineTransform(translationX: 20, y: 20)
        drawing.strokes.append(InkConverter.pkStroke(sample()[0]))
        let second = try reopened.save(drawing: drawing, pageID: loaded.id, size: CGSize(width: 595, height: 842), background: loaded.background)
        XCTAssertEqual(second.page.strokes[0].id, loaded.strokes[0].id)
        XCTAssertFalse(loaded.strokes.map(\.id).contains(second.page.strokes.last!.id))
    }

    func testCorruptFileIsQuarantinedNotOverwritten() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let store = PageStore(directory: dir)
        try Data("{ abîmé".utf8).write(to: store.fileURL)
        XCTAssertThrowsError(try store.load())
        let name = try XCTUnwrap(store.quarantine())
        XCTAssertTrue(FileManager.default.fileExists(atPath: dir.appendingPathComponent(name).path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: store.fileURL.path))
    }
}
