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

    func testToolMappingRoundTrip() {
        for tool in InkTool.allCases {
            XCTAssertEqual(InkConverter.tool(InkConverter.inkType(tool)), tool)
        }
    }

    func testStrokeRoundTripThroughPencilKitIsLossless() {
        for original in sample() {
            let back = InkConverter.stroke(from: InkConverter.pkStroke(original), id: original.id)
            XCTAssertEqual(back.tool, original.tool)
            XCTAssertEqual(back.points, original.points)
            XCTAssertEqual(back.transform, original.transform)
            XCTAssertEqual(back.mask, original.mask)
            XCTAssertEqual(back.createdAt, original.createdAt)
            XCTAssertEqual(back.randomSeed, original.randomSeed)
            XCTAssertEqual(back.color.r, original.color.r, accuracy: 0.004)
            XCTAssertEqual(back.color.a, original.color.a, accuracy: 0.004)
            XCTAssertEqual(back.identityKey, original.identityKey)
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
