import XCTest
@testable import NootyCore

final class NotebookTests: XCTestCase {
    private let a4 = PageInfo(background: .standard(.seyes))

    func testManifestRoundTrip() throws {
        let m = NotebookManifest(pages: [a4, PageInfo(width: 842, height: 595, background: .standard(.grid, paper: .ivory))], lastPageIndex: 1, updatedAt: 42)
        XCTAssertEqual(try NotebookCodec.decode(try NotebookCodec.encode(m)), m)
    }

    func testManifestRejectsEmptyAndDuplicatePagesAndClampsReadingPosition() throws {
        XCTAssertThrowsError(try NotebookCodec.decode(try NotebookCodec.encode(NotebookManifest(pages: [], updatedAt: 0))))
        XCTAssertThrowsError(try NotebookCodec.decode(try NotebookCodec.encode(NotebookManifest(pages: [a4, a4], updatedAt: 0))))
        let far = NotebookManifest(pages: [a4], lastPageIndex: 99, updatedAt: 0)
        XCTAssertEqual(try NotebookCodec.decode(try NotebookCodec.encode(far)).lastPageIndex, 0)
    }

    func testSeyesBackgroundUsesEightMillimetreSpacing() {
        let bg = Background.standard(.seyes, paper: .yellow)
        XCTAssertEqual(bg.spacing, 8 * 72 / 25.4, accuracy: 1e-9)
        XCTAssertEqual(bg.color, PaperColor.yellow.rgba)
    }

    func testLayoutStacksAndCentersPages() {
        let layout = PageLayout(sizes: [(600, 800), (400, 300), (600, 800)], gap: 20)
        XCTAssertEqual(layout.width, 600)
        XCTAssertEqual(layout.height, 800 + 20 + 300 + 20 + 800)
        XCTAssertEqual(layout.frames[1].x, 100)
        XCTAssertEqual(layout.frames[1].y, 820)
        XCTAssertEqual(layout.frames[2].y, 1140)
        XCTAssertEqual(PageLayout(sizes: []).height, 0)
    }

    func testPageIndexUsesContainingThenNearestPage() {
        let layout = PageLayout(sizes: [(600, 800), (600, 800)], gap: 20)
        XCTAssertEqual(layout.pageIndex(atY: -50), 0)
        XCTAssertEqual(layout.pageIndex(atY: 800), 0)
        XCTAssertEqual(layout.pageIndex(atY: 805), 0)
        XCTAssertEqual(layout.pageIndex(atY: 815), 1)
        XCTAssertEqual(layout.pageIndex(atY: 5000), 1)
    }

    private func stroke(y: Double, ty: Double = 0) -> Stroke {
        Stroke(tool: .pen, color: .ink, points: [InkPoint(x: 10, y: y), InkPoint(x: 50, y: y + 10)],
               transform: .translation(3, ty), createdAt: 0)
    }

    func testSplitAssignsByCentreAndPlaceIsItsInverse() {
        let layout = PageLayout(sizes: [(600, 800), (400, 300)], gap: 20)
        let first = stroke(y: 100)
        let second = stroke(y: 900)
        let movedDown = stroke(y: 100, ty: 850)
        let pages = layout.split([first, second, movedDown])
        XCTAssertEqual(pages.map(\.count), [1, 2])
        // Repère local : la deuxième page commence à x = 100, y = 820.
        XCTAssertEqual(pages[1][0].transform, .translation(3 - 100, -820))
        XCTAssertEqual(pages[1][0].points, second.points, "les points ne sont pas réécrits")
        let back = layout.place(pages)
        XCTAssertEqual(Set(back.map(\.id)), [first.id, second.id, movedDown.id])
        XCTAssertEqual(back.first { $0.id == movedDown.id }?.transform, movedDown.transform)
    }

    func testSplitThenPlaceIsStableOverManyCycles() {
        let layout = PageLayout(sizes: [(595.28, 841.89), (595.28, 841.89), (595.28, 841.89)])
        var strokes = StrokeGenerator.handwriting(count: 50, pageWidth: 595.28, pageHeight: 2500, seed: 5, createdAt: 0)
        for i in strokes.indices { strokes[i].transform = .translation(0.1 * Double(i) / 3, 1.0 / 7 * Double(i)) }
        let firstSplit = layout.split(strokes)
        var current = firstSplit
        for _ in 0..<10 { current = layout.split(layout.place(current)) }
        XCTAssertEqual(current, firstSplit)
    }

    func testReorderingPagesMovesTheirStrokes() {
        let old = PageLayout(sizes: [(600, 800), (600, 800)], gap: 20)
        var pages = old.split([stroke(y: 100), stroke(y: 900)])
        pages.insert([], at: 1) // nouvelle page insérée entre les deux
        let new = PageLayout(sizes: [(600, 800), (600, 800), (600, 800)], gap: 20)
        let placed = new.place(pages)
        XCTAssertEqual(new.pageIndex(for: placed[0]), 0)
        XCTAssertEqual(new.pageIndex(for: placed[1]), 2)
    }
}
