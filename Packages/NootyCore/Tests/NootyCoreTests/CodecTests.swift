import XCTest
@testable import NootyCore

final class CodecTests: XCTestCase {
    private func samplePage() -> Page {
        var page = Page.a4(id: UUID(uuidString: "6F1C2B9E-8C0D-4C1A-9E55-3B2F4D7A1E10")!, updatedAt: 1_700_000_000_000)
        page.background = .standard(.grid)
        page.strokes = StrokeGenerator.handwriting(count: 40, pageWidth: page.width, pageHeight: page.height, seed: 7, createdAt: 1_700_000_000_000)
        page.strokes[3].transform = AffineMatrix(a: 0.9, b: 0.1, c: -0.1, d: 0.9, tx: 12, ty: -3)
        page.strokes[5].mask = [.move(0, 0), .line(40, 0), .quad(50, 10, 40, 20), .cubic(30, 30, 10, 30, 0, 20), .close]
        page.strokes[7].tool = .fountainPen
        page.strokes[7].color = RGBA(hex: "#C62828")!
        return page
    }

    private func json(_ page: Page) throws -> [String: Any] {
        try JSONSerialization.jsonObject(with: try PageCodec.encode(page)) as! [String: Any]
    }

    private func decode(_ object: [String: Any]) throws -> Page {
        try PageCodec.decode(try JSONSerialization.data(withJSONObject: object))
    }

    func testRoundTripKeepsEverythingUpToFloat32Precision() throws {
        let page = samplePage()
        let back = try PageCodec.decode(try PageCodec.encode(page))
        XCTAssertEqual(back.id, page.id)
        XCTAssertEqual(back.background, page.background)
        XCTAssertEqual(back.updatedAt, page.updatedAt)
        XCTAssertEqual(back.strokes.count, page.strokes.count)
        for (s, o) in zip(back.strokes, page.strokes) {
            XCTAssertEqual(s.id, o.id)
            XCTAssertEqual(s.tool, o.tool)
            XCTAssertEqual(s.color, o.color)
            XCTAssertEqual(s.transform, o.transform)
            XCTAssertEqual(s.mask, o.mask)
            XCTAssertEqual(s.createdAt, o.createdAt)
            XCTAssertEqual(s.randomSeed, o.randomSeed)
            XCTAssertEqual(s.points.count, o.points.count)
            for (p, q) in zip(s.points, o.points) {
                for (a, b) in zip(p.components, q.components) { XCTAssertEqual(a, b, accuracy: max(1e-4, abs(b) * 1e-6)) }
            }
        }
    }

    func testSecondRoundTripIsByteIdentical() throws {
        let once = try PageCodec.encode(try PageCodec.decode(try PageCodec.encode(samplePage())))
        let twice = try PageCodec.encode(try PageCodec.decode(once))
        XCTAssertEqual(once, twice)
    }

    func testPointPackingIsExactForFloat32Values() throws {
        let pts = [InkPoint(x: 1.5, y: -2.25, timeOffset: 0.125, width: 3, height: 2, opacity: 0.5, force: 0.75, azimuth: 1, altitude: 0.5, secondaryScale: 2)]
        XCTAssertEqual(try PointPacking.unpack(try PointPacking.pack(pts)), pts)
    }

    func testPointPackingRejectsNonFiniteAndMalformedData() {
        XCTAssertThrowsError(try PointPacking.pack([InkPoint(x: .nan, y: 0)]))
        XCTAssertThrowsError(try PointPacking.unpack("pas du base64 !"))
        XCTAssertThrowsError(try PointPacking.unpack(Data([1, 2, 3]).base64EncodedString()))
        XCTAssertThrowsError(try PointPacking.unpack(""))
        var words = [UInt32](repeating: 0, count: InkPoint.componentCount)
        words[0] = Float32.nan.bitPattern.littleEndian
        let text = words.withUnsafeBufferPointer { Data(buffer: $0) }.base64EncodedString()
        XCTAssertThrowsError(try PointPacking.unpack(text))
        let tooMany = [InkPoint](repeating: InkPoint(x: 0, y: 0), count: 3)
        XCTAssertThrowsError(try PointPacking.unpack(try PointPacking.pack(tooMany), maxPoints: 2))
    }

    func testRejectsNewerSchemaVersion() throws {
        var j = try json(samplePage())
        j["schemaVersion"] = NootyFormat.schemaVersion + 1
        XCTAssertThrowsError(try decode(j)) { XCTAssertEqual($0 as? FormatError, .unsupportedVersion(NootyFormat.schemaVersion + 1)) }
    }

    func testRejectsForeignFiles() {
        XCTAssertThrowsError(try PageCodec.decode(Data("not json".utf8))) { XCTAssertEqual($0 as? FormatError, .notNooty) }
        XCTAssertThrowsError(try PageCodec.decode(Data(#"{"format":"autre","schemaVersion":1}"#.utf8))) {
            XCTAssertEqual($0 as? FormatError, .notNooty)
        }
    }

    func testRejectsInvalidContent() throws {
        let mutations: [(String, (inout [String: Any]) -> Void)] = [
            ("objets absents", { $0["page"] = ["id": "x"] }),
            ("identifiant de page", { j in Self.page(&j) { $0["id"] = "pas-un-uuid" } }),
            ("dimensions", { j in Self.page(&j) { $0["width"] = 1e9 } }),
            ("fond inconnu", { j in Self.page(&j) { p in var bg = p["background"] as! [String: Any]; bg["kind"] = "x"; p["background"] = bg } }),
            ("couleur", { j in Self.stroke(&j, 0) { $0["color"] = "red;" } }),
            ("outil", { j in Self.stroke(&j, 0) { $0["tool"] = "script" } }),
            ("transformation", { j in Self.stroke(&j, 0) { $0["transform"] = [1, 0] } }),
            ("composantes", { j in Self.stroke(&j, 0) { $0["pointComponents"] = 6 } }),
            ("points", { j in Self.stroke(&j, 0) { $0["points"] = "%%%" } }),
            ("masque sans départ", { j in Self.stroke(&j, 0) { $0["mask"] = [["op": "l", "p": [1, 2]]] } }),
            ("masque mal formé", { j in Self.stroke(&j, 0) { $0["mask"] = [["op": "c", "p": [1, 2]]] } }),
            ("doublon", { j in
                var id = ""
                Self.stroke(&j, 0) { id = $0["id"] as! String }
                Self.stroke(&j, 1) { $0["id"] = id }
            }),
        ]
        for (name, mutate) in mutations {
            var j = try json(samplePage())
            mutate(&j)
            XCTAssertThrowsError(try decode(j), name)
        }
    }

    func testRejectsOversizedInput() {
        XCTAssertEqual(PageCodec.maxBytes, 256 * 1024 * 1024)
        // On vérifie la garde sans allouer 256 Mo : la taille est contrôlée avant toute analyse.
        XCTAssertThrowsError(try PageCodec.decode(Data(count: PageCodec.maxBytes + 1))) { XCTAssertEqual($0 as? FormatError, .tooLarge) }
    }

    private static func page(_ j: inout [String: Any], _ f: (inout [String: Any]) -> Void) {
        var p = j["page"] as! [String: Any]
        f(&p)
        j["page"] = p
    }

    private static func stroke(_ j: inout [String: Any], _ i: Int, _ f: (inout [String: Any]) -> Void) {
        page(&j) { p in
            var strokes = p["strokes"] as! [[String: Any]]
            f(&strokes[i])
            p["strokes"] = strokes
        }
    }
}
