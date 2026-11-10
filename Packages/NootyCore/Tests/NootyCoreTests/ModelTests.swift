import XCTest
@testable import NootyCore

final class ModelTests: XCTestCase {
    func testHexRoundTrip() {
        let c = RGBA(hex: "#1D2A44CC")!
        XCTAssertEqual(c.hex, "#1D2A44CC")
        XCTAssertEqual(RGBA(hex: "#FFFFFF")?.hex, "#FFFFFFFF")
        XCTAssertEqual(RGBA(hex: "#000000")?.a, 1)
    }

    func testHexRejectsInvalidInput() {
        for bad in ["FFFFFF", "#FFF", "#GGGGGG", "#+FFFFF", "#12345", "#123456789", ""] {
            XCTAssertNil(RGBA(hex: bad), bad)
        }
    }

    func testColorClampsOutOfRangeComponents() {
        let c = RGBA(r: 2, g: -1, b: .nan, a: 0.5)
        XCTAssertEqual([c.r, c.g, c.b, c.a], [1, 0, 0, 0.5])
    }

    func testMatrixInverseGivesIdentity() {
        let m = AffineMatrix(a: 2, b: 0.5, c: -1, d: 3, tx: 10, ty: -4)
        let r = m.concatenating(m.inverted!)
        for (v, e) in zip(r.values, AffineMatrix.identity.values) { XCTAssertEqual(v, e, accuracy: 1e-10) }
    }

    func testConcatenatingAppliesSelfFirst() {
        let translate = AffineMatrix.translation(5, 0)
        let scale = AffineMatrix.scale(2, 2)
        XCTAssertEqual(translate.concatenating(scale).apply(1, 1).x, 12)
        XCTAssertEqual(scale.concatenating(translate).apply(1, 1).x, 7)
    }

    func testRotationQuarterTurn() {
        let p = AffineMatrix.rotation(.pi / 2).apply(1, 0)
        XCTAssertEqual(p.x, 0, accuracy: 1e-12)
        XCTAssertEqual(p.y, 1, accuracy: 1e-12)
    }

    func testSingularMatrixHasNoInverse() {
        XCTAssertNil(AffineMatrix(a: 1, b: 2, c: 2, d: 4, tx: 0, ty: 0).inverted)
    }

    func testBoundsIncludeWidthAndTransform() {
        var s = Stroke(tool: .pen, color: .ink, points: [
            InkPoint(x: 10, y: 10, width: 4, height: 2),
            InkPoint(x: 50, y: 30, width: 4, height: 2),
        ], createdAt: 0)
        XCTAssertEqual(s.bounds, BBox(minX: 8, minY: 8, maxX: 52, maxY: 32))
        s.transform = .translation(100, -5)
        XCTAssertEqual(s.bounds, BBox(minX: 108, minY: 3, maxX: 152, maxY: 27))
        s.points = []
        XCTAssertNil(s.bounds)
    }

    func testBBoxUnionAndIntersection() {
        let a = BBox(minX: 0, minY: 0, maxX: 10, maxY: 10)
        XCTAssertTrue(a.intersects(BBox(minX: 10, minY: 10, maxX: 20, maxY: 20)))
        XCTAssertFalse(a.intersects(BBox(minX: 10.1, minY: 0, maxX: 20, maxY: 10)))
        XCTAssertEqual(a.union(BBox(minX: -2, minY: 5, maxX: 3, maxY: 30)), BBox(minX: -2, minY: 0, maxX: 10, maxY: 30))
    }

    func testStrokeStats() {
        let s = Stroke(tool: .pen, color: .ink, points: [
            InkPoint(x: 0, y: 0, timeOffset: 0, force: 0.2, altitude: .pi / 4),
            InkPoint(x: 1, y: 0, timeOffset: 0.3, force: 1.8, altitude: .pi / 2),
        ], createdAt: 0)
        let st = StrokeStats(s)!
        XCTAssertEqual(st.forceMin, 0.2)
        XCTAssertEqual(st.forceMax, 1.8)
        XCTAssertEqual(st.altitudeMin, 45, accuracy: 1e-9)
        XCTAssertEqual(st.altitudeMax, 90, accuracy: 1e-9)
        XCTAssertEqual(st.durationSeconds, 0.3)
    }

    func testGeneratorIsDeterministicAndInsidePage() {
        let a = StrokeGenerator.handwriting(count: 500, pageWidth: Page.a4Width, pageHeight: Page.a4Height, seed: 42, createdAt: 1000)
        let b = StrokeGenerator.handwriting(count: 500, pageWidth: Page.a4Width, pageHeight: Page.a4Height, seed: 42, createdAt: 1000)
        XCTAssertEqual(a, b)
        XCTAssertEqual(Set(a.map(\.id)).count, 500)
        for s in a {
            let bb = s.bounds!
            XCTAssertGreaterThan(bb.minX, 0)
            XCTAssertLessThan(bb.maxX, Page.a4Width)
            XCTAssertGreaterThan(bb.minY, 0)
            XCTAssertLessThan(bb.maxY, Page.a4Height)
        }
    }
}
