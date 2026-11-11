import XCTest
@testable import NootyCore

final class ElementTests: XCTestCase {
    private func page() -> Page {
        var p = Page.a4(updatedAt: 5)
        p.elements = [
            .image(ImageElement(frame: Rect(x: 10, y: 20, width: 200, height: 100), rotation: 0.3, resource: ResourceName.make("jpg"), crop: Rect(x: 0.1, y: 0, width: 0.8, height: 1))),
            .text(TextElement(frame: Rect(x: 40, y: 300, width: 250, height: 60), text: "Définition : bornage", font: .serif, fontSize: 18, bold: true, alignment: .center, fill: RGBA(hex: "#FFE14D")!)),
            .tape(TapeElement(frame: Rect(x: 40, y: 400, width: 300, height: 30), color: RGBA(hex: "#7CC8FF")!)),
        ]
        return p
    }

    func testElementsRoundTrip() throws {
        let p = page()
        XCTAssertEqual(try PageCodec.decode(try PageCodec.encode(p)), p)
    }

    func testVersionOnePageWithoutElementsIsMigrated() throws {
        var json = try JSONSerialization.jsonObject(with: try PageCodec.encode(Page.a4(updatedAt: 1))) as! [String: Any]
        json["schemaVersion"] = 1
        var inner = json["page"] as! [String: Any]
        inner.removeValue(forKey: "elements")
        json["page"] = inner
        let decoded = try PageCodec.decode(try JSONSerialization.data(withJSONObject: json))
        XCTAssertEqual(decoded.elements, [])
    }

    func testRejectsPathTraversalAndBadElements() throws {
        for mutate in [
            { (e: inout [String: Any]) in e["resource"] = "../../secret.jpg" },
            { (e: inout [String: Any]) in e["type"] = "script" },
            { (e: inout [String: Any]) in e["frame"] = ["x": 0, "y": 0, "w": -5, "h": 10] },
        ] {
            var json = try JSONSerialization.jsonObject(with: try PageCodec.encode(page())) as! [String: Any]
            var inner = json["page"] as! [String: Any]
            var elements = inner["elements"] as! [[String: Any]]
            mutate(&elements[0])
            inner["elements"] = elements
            json["page"] = inner
            XCTAssertThrowsError(try PageCodec.decode(try JSONSerialization.data(withJSONObject: json)))
        }
    }

    func testResourceNames() {
        XCTAssertTrue(ResourceName.isValid(ResourceName.make("PDF")))
        XCTAssertFalse(ResourceName.isValid("photo.jpg"))
        XCTAssertFalse(ResourceName.isValid("\(UUID().uuidString).exe"))
        XCTAssertFalse(ResourceName.isValid("../\(UUID().uuidString).png"))
    }
}

final class ManifestFeatureTests: XCTestCase {
    func testManifestWithBackdropsRecordingsAndCardsRoundTrips() throws {
        let rec = AudioRecording(
            title: "Cours 1", resource: ResourceName.make("m4a"),
            spans: [RecordingSpan(wallStart: 1_000_000, offset: 0, length: 60), RecordingSpan(wallStart: 1_120_000, offset: 60, length: 30)],
            transcript: [TranscriptSegment(start: 1, end: 3, text: "Bonjour à tous")], summary: "Résumé"
        )
        let m = NotebookManifest(
            pages: [
                PageInfo(background: .standard(.seyes), title: "Introduction", bookmarked: true),
                PageInfo(width: 612, height: 792, background: .standard(.blank), backdrop: .pdf(resource: ResourceName.make("pdf"), pageIndex: 3)),
                PageInfo(background: .standard(.blank), backdrop: .image(resource: ResourceName.make("jpg"))),
            ],
            updatedAt: 9, recordings: [rec], cards: [Flashcard(front: "Q", back: "R", box: 2, due: 50)]
        )
        let back = try NotebookCodec.decode(try NotebookCodec.encode(m))
        XCTAssertEqual(back, m)
        XCTAssertEqual(back.referencedResources.count, 3)
    }

    func testPaperSizes() {
        XCTAssertEqual(PaperSize.a4.size(landscape: true).width, 841.89)
        XCTAssertEqual(PaperSize.a5.size(landscape: false).height, 595.28)
    }
}

final class AudioTests: XCTestCase {
    private let rec = AudioRecording(
        title: "Cours", resource: ResourceName.make("m4a"),
        spans: [RecordingSpan(wallStart: 10_000, offset: 0, length: 20), RecordingSpan(wallStart: 50_000, offset: 20, length: 10)]
    )

    func testWallToAudioMappingAcrossPause() {
        XCTAssertEqual(rec.audioTime(atWall: 10_000), 0)
        XCTAssertEqual(rec.audioTime(atWall: 25_000), 15)
        XCTAssertNil(rec.audioTime(atWall: 40_000), "pendant la pause")
        XCTAssertEqual(rec.audioTime(atWall: 55_000), 25)
        XCTAssertNil(rec.audioTime(atWall: 70_000))
        XCTAssertEqual(rec.duration, 30)
    }

    func testAudioToWallIsTheInverse() {
        for t in stride(from: 0.0, through: 30, by: 2.5) {
            let wall = rec.wallTime(atAudio: t)!
            XCTAssertEqual(rec.audioTime(atWall: wall)!, t, accuracy: 1e-9)
        }
    }
}

final class FlashcardTests: XCTestCase {
    func testLeitnerPromotesAndResets() {
        var c = Flashcard(front: "a", back: "b")
        let day = 86_400_000.0
        c = Leitner.review(c, knew: true, now: 0)
        XCTAssertEqual(c.box, 1)
        XCTAssertEqual(c.due, day)
        c = Leitner.review(c, knew: true, now: day)
        XCTAssertEqual(c.box, 2)
        XCTAssertEqual(c.due, day + 3 * day)
        c = Leitner.review(c, knew: false, now: 5 * day)
        XCTAssertEqual(c.box, 0)
        XCTAssertEqual(c.due, 5 * day)
        for _ in 0..<10 { c = Leitner.review(c, knew: true, now: 0) }
        XCTAssertEqual(c.box, Leitner.intervals.count - 1)
    }

    func testDueCardsOrder() {
        let a = Flashcard(front: "a", back: "", due: 30), b = Flashcard(front: "b", back: "", due: 10), later = Flashcard(front: "c", back: "", due: 999)
        XCTAssertEqual(Leitner.dueCards([a, b, later], now: 100).map(\.front), ["b", "a"])
    }
}

final class SearchTests: XCTestCase {
    func testNormalizeIgnoresCaseAccentsAndSpacing() {
        XCTAssertEqual(TextSearch.normalize("  Élève\n  ÉCOLE "), "eleve ecole")
    }

    func testSnippetFindsAccentInsensitiveMatch() {
        let text = String(repeating: "mot ", count: 30) + "le bornage est une opération" + String(repeating: " fin", count: 30)
        let s = TextSearch.snippet(text, query: "BORNAGE")!
        XCTAssertTrue(s.contains("bornage"))
        XCTAssertTrue(s.hasPrefix("…") && s.hasSuffix("…"))
        XCTAssertNil(TextSearch.snippet(text, query: "absent"))
        XCTAssertNil(TextSearch.snippet(text, query: "   "))
    }

    func testIndexSearchAndRoundTrip() throws {
        let p1 = UUID(), p2 = UUID(), r = UUID()
        let index = NotebookTextIndex(pages: [p1: "Introduction", p2: "Division parcellaire"], recordings: [r: "la division du terrain"])
        let hits = index.search("division", pageOrder: [p1, p2], recordingOrder: [r])
        XCTAssertEqual(hits.map(\.pageIndex), [1, nil])
        XCTAssertEqual(hits.last?.recordingID, r)
        XCTAssertEqual(NotebookTextIndex.decode(try index.encoded()), index)
        XCTAssertEqual(NotebookTextIndex.decode(Data("abîmé".utf8)), NotebookTextIndex())
    }

    func testLibrarySearchSkipsTrash() {
        let a = LibraryEntry(kind: .notebook, title: "Droit foncier", createdAt: 0)
        var b = LibraryEntry(kind: .notebook, title: "Droit public", createdAt: 0)
        b.trashedAt = 1
        let index = LibraryIndex(items: [a, b, LibraryEntry(kind: .whiteboard, title: "Schéma", createdAt: 0)])
        XCTAssertEqual(index.search("droit").map(\.title), ["Droit foncier"])
        XCTAssertEqual(index.search("SCHEMA").count, 1)
    }

    func testFoldersStillComeFirstWithNewKinds() {
        let index = LibraryIndex(items: [
            LibraryEntry(kind: .whiteboard, title: "B", createdAt: 0),
            LibraryEntry(kind: .folder, title: "Z", createdAt: 0),
            LibraryEntry(kind: .document, title: "A", createdAt: 0),
        ])
        XCTAssertEqual(index.children(of: nil).map(\.title), ["Z", "A", "B"])
    }
}

final class ShapeTests: XCTestCase {
    private func sample(_ shape: ShapeSpec, jitter: Double = 0) -> [(x: Double, y: Double)] {
        var rng = SplitMix64(seed: 3)
        return shape.polylines(step: 4)[0].map { ($0.x + (rng.unit() - 0.5) * jitter, $0.y + (rng.unit() - 0.5) * jitter) }
    }

    func testRecognizesBasicShapes() {
        XCTAssertEqual(ShapeRecognizer.recognize(sample(ShapeSpec(kind: .line, ax: 0, ay: 0, bx: 200, by: 50), jitter: 2))?.kind, .line)
        XCTAssertEqual(ShapeRecognizer.recognize(sample(ShapeSpec(kind: .rectangle, ax: 0, ay: 0, bx: 200, by: 120), jitter: 3))?.kind, .rectangle)
        XCTAssertEqual(ShapeRecognizer.recognize(sample(ShapeSpec(kind: .ellipse, ax: 0, ay: 0, bx: 200, by: 120), jitter: 3))?.kind, .ellipse)
        XCTAssertEqual(ShapeRecognizer.recognize(sample(ShapeSpec(kind: .triangle, ax: 0, ay: 0, bx: 200, by: 160), jitter: 2))?.kind, .triangle)
    }

    func testRejectsScribblesAndTinyStrokes() {
        var rng = SplitMix64(seed: 9)
        let scribble = (0..<80).map { _ in (x: rng.unit() * 200, y: rng.unit() * 200) }
        XCTAssertNil(ShapeRecognizer.recognize(scribble))
        XCTAssertNil(ShapeRecognizer.recognize([(0, 0), (1, 1), (2, 2), (3, 3), (4, 4), (5, 5)]))
    }

    func testArrowHasHead() {
        XCTAssertEqual(ShapeSpec(kind: .arrow, ax: 0, ay: 0, bx: 100, by: 0).polylines().count, 2)
    }
}

final class ExportTests: XCTestCase {
    func testExportRoundTripAndMissingResource() throws {
        let image = ResourceName.make("png"), audio = ResourceName.make("m4a")
        var page = Page.a4(updatedAt: 1)
        page.strokes = StrokeGenerator.handwriting(count: 5, pageWidth: page.width, pageHeight: page.height, seed: 1, createdAt: 0)
        page.elements = [.image(ImageElement(frame: Rect(x: 0, y: 0, width: 50, height: 50), resource: image))]
        let manifest = NotebookManifest(pages: [PageInfo(id: page.id, background: page.background)], updatedAt: 1, recordings: [AudioRecording(title: "A", resource: audio)])
        let export = NotebookExport(title: "Cours", kind: .notebook, color: .ink, manifest: manifest, pages: [page], resources: [image: Data([1, 2, 3]), audio: Data([4])])
        let back = try ExportCodec.decode(try ExportCodec.encode(export))
        XCTAssertEqual(back.title, "Cours")
        XCTAssertEqual(back.resources, export.resources)
        XCTAssertEqual(back.pages.first?.elements, page.elements)
        XCTAssertEqual(back.pages.first?.strokes.count, 5)

        var broken = export
        broken.resources.removeValue(forKey: audio)
        XCTAssertThrowsError(try ExportCodec.decode(try ExportCodec.encode(broken)))
        XCTAssertThrowsError(try ExportCodec.decode(try PageCodec.encode(page)))
    }
}
