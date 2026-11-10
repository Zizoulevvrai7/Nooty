import XCTest
@testable import NootyCore

final class IdentityTests: XCTestCase {
    private let base = StrokeGenerator.handwriting(count: 20, pageWidth: 600, pageHeight: 800, seed: 3, createdAt: 1_000_000)

    private func fresh(_ strokes: [Stroke]) -> [Stroke] {
        strokes.map { var s = $0; s.id = UUID(); return s }
    }

    func testUnchangedStrokesKeepTheirIDs() {
        let out = IdentityMatcher.assignIDs(previous: base, current: fresh(base))
        XCTAssertEqual(out.map(\.id), base.map(\.id))
    }

    func testMovedAndRecoloredStrokeKeepsItsID() {
        var current = fresh(base)
        current[4].transform = .translation(30, 40)
        current[4].color = RGBA(hex: "#C62828")!
        XCTAssertEqual(IdentityMatcher.assignIDs(previous: base, current: current)[4].id, base[4].id)
    }

    func testSplitStrokeGetsNewIDs() {
        var current = fresh(base)
        var left = current[2]
        var right = current[2]
        left.points = Array(left.points.prefix(5))
        right.points = Array(right.points.suffix(from: 5))
        current.replaceSubrange(2...2, with: [left, right])
        let out = IdentityMatcher.assignIDs(previous: base, current: current)
        XCTAssertFalse(base.map(\.id).contains(out[2].id))
        XCTAssertFalse(base.map(\.id).contains(out[3].id))
        XCTAssertEqual(out[4].id, base[3].id)
    }

    func testExactDuplicatesGetDistinctIDs() {
        let current = fresh([base[0], base[0], base[1]])
        let out = IdentityMatcher.assignIDs(previous: Array(base.prefix(2)), current: current)
        XCTAssertEqual(out[0].id, base[0].id)
        XCTAssertNotEqual(out[1].id, base[0].id)
        XCTAssertEqual(out[2].id, base[1].id)
        XCTAssertEqual(Set(out.map(\.id)).count, 3)
    }

    func testKeyToleratesSubMillisecondDateNoise() {
        var a = base[0]
        a.createdAt = 1_700_000_000_123
        var b = a
        b.createdAt = 1_700_000_000_123.0002
        XCTAssertEqual(a.identityKey, b.identityKey)
    }
}
