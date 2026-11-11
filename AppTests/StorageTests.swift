import AVFoundation
import NootyCore
import UIKit
import PDFKit
import PencilKit
import XCTest
@testable import Nooty

final class StorageTests: XCTestCase {
    private var dir: URL!

    override func setUpWithError() throws {
        dir = FileManager.default.temporaryDirectory.appendingPathComponent("nooty-tests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: dir)
    }

    private func pageStrokes(_ count: Int, seed: UInt64) -> [Stroke] {
        StrokeGenerator.handwriting(count: count, pageWidth: Page.a4Width, pageHeight: Page.a4Height, seed: seed, createdAt: 1_700_000_000_000 + Double(seed) * 100_000)
    }

    private func makeNotebook(pages: Int) throws -> (URL, NotebookManifest) {
        let url = dir.appendingPathComponent(UUID().uuidString)
        let manifest = NotebookManifest(pages: (0..<pages).map { _ in PageInfo(background: .standard(.seyes)) }, updatedAt: 1)
        try NotebookStore.create(directory: url, manifest: manifest)
        return (url, manifest)
    }

    private func pageFiles(_ url: URL) -> [String] {
        ((try? FileManager.default.contentsOfDirectory(atPath: url.appendingPathComponent("pages").path)) ?? []).sorted()
    }

    func testSaveWritesOnlyChangedPagesAndReloadsIdentically() throws {
        let (url, manifest) = try makeNotebook(pages: 3)
        let layout = PageLayout(pages: manifest.pages)
        let opened = try NotebookStore.open(directory: url)
        XCTAssertEqual(opened.pages.map(\.count), [0, 0, 0])

        var drawing = InkConverter.drawing(layout.place([pageStrokes(20, seed: 1), pageStrokes(15, seed: 2), []]))
        XCTAssertEqual(try opened.store.save(drawing: drawing, elements: Array(repeating: [], count: manifest.pages.count), manifest: manifest).pagesWritten, 3)
        XCTAssertEqual(try opened.store.save(drawing: drawing, elements: Array(repeating: [], count: manifest.pages.count), manifest: manifest).pagesWritten, 0, "rien n’a changé")

        // Un trait ajouté sur la deuxième page ne réécrit que cette page.
        let extra = layout.place([[], pageStrokes(1, seed: 9), []])
        drawing.strokes.append(contentsOf: extra.map(InkConverter.pkStroke))
        XCTAssertEqual(try opened.store.save(drawing: drawing, elements: Array(repeating: [], count: manifest.pages.count), manifest: manifest).pagesWritten, 1)

        let reopened = try NotebookStore.open(directory: url)
        XCTAssertEqual(reopened.pages.map(\.count), [20, 16, 0])
        XCTAssertEqual(reopened.damagedPages, 0)

        // Rouvrir puis enregistrer sans rien toucher ne réécrit aucune page, et les identifiants sont conservés.
        let again = InkConverter.drawing(layout.place(reopened.pages))
        reopened.store.prime(drawing: again, manifest: reopened.manifest)
        XCTAssertEqual(try reopened.store.save(drawing: again, elements: reopened.elements, manifest: reopened.manifest).pagesWritten, 0)
        let third = try NotebookStore.open(directory: url)
        XCTAssertEqual(third.pages.map { $0.map(\.id) }, reopened.pages.map { $0.map(\.id) })
    }

    func testStrokeMovedToAnotherPageKeepsItsIdentifier() throws {
        let (url, manifest) = try makeNotebook(pages: 2)
        let layout = PageLayout(pages: manifest.pages)
        let store = try NotebookStore.open(directory: url).store
        var drawing = InkConverter.drawing(layout.place([pageStrokes(3, seed: 4), []]))
        _ = try store.save(drawing: drawing, elements: Array(repeating: [], count: manifest.pages.count), manifest: manifest)
        let before = try NotebookStore.open(directory: url).pages[0][0].id

        drawing.strokes[0].transform = drawing.strokes[0].transform.translatedBy(x: 0, y: CGFloat(layout.frames[1].y))
        _ = try store.save(drawing: drawing, elements: Array(repeating: [], count: manifest.pages.count), manifest: manifest)
        let after = try NotebookStore.open(directory: url)
        XCTAssertEqual(after.pages.map(\.count), [2, 1])
        XCTAssertEqual(after.pages[1][0].id, before)
    }

    func testRemovingAPageDeletesItsFile() throws {
        let (url, manifest) = try makeNotebook(pages: 3)
        let layout = PageLayout(pages: manifest.pages)
        let store = try NotebookStore.open(directory: url).store
        _ = try store.save(drawing: InkConverter.drawing(layout.place([pageStrokes(4, seed: 1), pageStrokes(4, seed: 2), pageStrokes(4, seed: 3)])), elements: Array(repeating: [], count: manifest.pages.count), manifest: manifest)
        XCTAssertEqual(pageFiles(url).count, 3)

        var smaller = manifest
        let removed = smaller.pages.remove(at: 1)
        let newLayout = PageLayout(pages: smaller.pages)
        _ = try store.save(drawing: InkConverter.drawing(newLayout.place([pageStrokes(4, seed: 1), pageStrokes(4, seed: 3)])), elements: Array(repeating: [], count: smaller.pages.count), manifest: smaller)
        XCTAssertEqual(pageFiles(url).count, 2)
        XCTAssertFalse(pageFiles(url).contains("\(removed.id.uuidString).json"))
        XCTAssertEqual(try NotebookStore.open(directory: url).pages.map(\.count), [4, 4])
    }

    func testUnreadablePageIsSetAsideAndReported() throws {
        let (url, manifest) = try makeNotebook(pages: 2)
        let layout = PageLayout(pages: manifest.pages)
        let store = try NotebookStore.open(directory: url).store
        _ = try store.save(drawing: InkConverter.drawing(layout.place([pageStrokes(5, seed: 1), pageStrokes(5, seed: 2)])), elements: Array(repeating: [], count: manifest.pages.count), manifest: manifest)
        let victim = url.appendingPathComponent("pages/\(manifest.pages[0].id.uuidString).json")
        try Data("{ abîmé".utf8).write(to: victim)

        let opened = try NotebookStore.open(directory: url)
        XCTAssertEqual(opened.damagedPages, 1)
        XCTAssertEqual(opened.pages.map(\.count), [0, 5])
        XCTAssertFalse(FileManager.default.fileExists(atPath: victim.path))
        XCTAssertTrue(pageFiles(url).contains { $0.contains("illisible") }, "le fichier abîmé est conservé à part")
    }

    func testDuplicateGetsNewIdentifiers() throws {
        let (url, manifest) = try makeNotebook(pages: 2)
        let layout = PageLayout(pages: manifest.pages)
        _ = try NotebookStore.open(directory: url).store.save(
            drawing: InkConverter.drawing(layout.place([pageStrokes(6, seed: 1), pageStrokes(2, seed: 2)])), elements: [[], []], manifest: manifest
        )
        let copyURL = dir.appendingPathComponent("copie")
        let newID = UUID()
        try NotebookStore.duplicate(from: url, to: copyURL, newID: newID)
        let original = try NotebookStore.open(directory: url)
        let copy = try NotebookStore.open(directory: copyURL)
        XCTAssertEqual(copy.manifest.id, newID)
        XCTAssertEqual(copy.pages.map(\.count), [6, 2])
        XCTAssertTrue(Set(copy.manifest.pages.map(\.id)).isDisjoint(with: original.manifest.pages.map(\.id)))
        XCTAssertTrue(Set(copy.pages.flatMap { $0.map(\.id) }).isDisjoint(with: original.pages.flatMap { $0.map(\.id) }))
        XCTAssertEqual(copy.pages[0].map(\.points), original.pages[0].map(\.points))
    }

    func testLibraryPersistsAcrossRelaunchAndDeletesFiles() throws {
        let root = dir.appendingPathComponent("Bibliotheque")
        let store = LibraryStore(root: root)
        let folder = store.createFolder(title: "  Droit  ", parent: nil)
        let notebook = try store.createNotebook(title: "", parent: folder.id, background: .standard(.seyes))
        XCTAssertEqual(folder.title, "Droit")
        XCTAssertTrue(FileManager.default.fileExists(atPath: store.notebookDirectory(notebook.id).appendingPathComponent("carnet.json").path))
        try store.duplicateNotebook(notebook.id)

        let relaunched = LibraryStore(root: root)
        XCTAssertNil(relaunched.startupWarning)
        XCTAssertEqual(relaunched.index, store.index)
        XCTAssertEqual(relaunched.index.children(of: folder.id).count, 2)

        relaunched.mutate { $0.trash(folder.id, now: 5) }
        relaunched.emptyTrash()
        XCTAssertTrue(relaunched.index.items.isEmpty)
        XCTAssertFalse(FileManager.default.fileExists(atPath: relaunched.notebookDirectory(notebook.id).path))
    }

    func testUnreadableIndexIsRebuiltFromNotebooksOnDisk() throws {
        let root = dir.appendingPathComponent("Bibliotheque")
        let store = LibraryStore(root: root)
        let notebook = try store.createNotebook(title: "Cours", parent: nil, background: .standard(.ruled))
        try Data("{ abîmé".utf8).write(to: root.appendingPathComponent("bibliotheque.json"))

        let recovered = LibraryStore(root: root)
        XCTAssertNotNil(recovered.startupWarning)
        XCTAssertEqual(recovered.index.items.map(\.id), [notebook.id])
        XCTAssertNoThrow(try NotebookStore.open(directory: recovered.notebookDirectory(notebook.id)))
        let names = try FileManager.default.contentsOfDirectory(atPath: root.path)
        XCTAssertTrue(names.contains { $0.hasPrefix("bibliotheque.illisible") })
    }

    func testElementsAndResourcesPersistAndExportRoundTrip() throws {
        let root = dir.appendingPathComponent("Bibliotheque")
        let library = LibraryStore(root: root)
        let entry = try library.createNotebook(title: "Cours", parent: nil, background: .standard(.seyes))
        let nbDir = library.notebookDirectory(entry.id)
        let opened = try NotebookStore.open(directory: nbDir)
        let image = UIGraphicsImageRenderer(size: CGSize(width: 40, height: 30)).image { ctx in
            UIColor.red.setFill()
            ctx.fill(CGRect(x: 0, y: 0, width: 40, height: 30))
        }
        let name = try opened.store.addResource(image.pngData()!, ext: "png")
        let elements: [PageElements] = [[
            .image(ImageElement(frame: Rect(x: 10, y: 10, width: 80, height: 60), resource: name)),
            .text(TextElement(frame: Rect(x: 20, y: 200, width: 200, height: 40), text: "Bornage")),
            .tape(TapeElement(frame: Rect(x: 20, y: 300, width: 200, height: 20), color: .ink)),
        ]]
        let drawing = InkConverter.drawing(pageStrokes(4, seed: 2))
        _ = try opened.store.save(drawing: drawing, elements: elements, manifest: opened.manifest)
        let reopened = try NotebookStore.open(directory: nbDir)
        XCTAssertEqual(reopened.elements, elements)

        let url = try library.exportNooty(entry.id)
        let imported = try library.importNooty(try Data(contentsOf: url), parent: nil)
        XCTAssertNotEqual(imported.id, entry.id)
        let copy = try NotebookStore.open(directory: library.notebookDirectory(imported.id))
        XCTAssertEqual(copy.elements.first?.count, 3)
        XCTAssertEqual(copy.pages.first?.count, 4)
        XCTAssertTrue(FileManager.default.fileExists(atPath: copy.store.resourceURL(name).path))

        // Une ressource devenue inutile est supprimée par le ménage.
        opened.store.collectGarbage(manifest: opened.manifest, elements: [[]])
        XCTAssertFalse(FileManager.default.fileExists(atPath: opened.store.resourceURL(name).path))
    }

    func testPDFExportKeepsPageCountAndSize() throws {
        let info = PageInfo(width: 612, height: 792, background: .standard(.grid))
        let pages: [(info: PageInfo, strokes: [Stroke], elements: [PageElement])] = [(info, pageStrokes(3, seed: 1), []), (info, [], [])]
        let data = PageRenderer.pdf(pages: pages, resources: dir)
        let document = try XCTUnwrap(PDFDocument(data: data))
        XCTAssertEqual(document.pageCount, 2)
        XCTAssertEqual(document.page(at: 0)?.bounds(for: .mediaBox).width ?? 0, 612, accuracy: 0.5)
        // Le PDF exporté se réimporte en pages de mêmes dimensions.
        let imported = try Importers.pdfPages(from: data, into: dir)
        XCTAssertEqual(imported.count, 2)
        XCTAssertEqual(imported[0].width, 612, accuracy: 0.5)
    }

    func testMP3EncoderProducesValidFrames() throws {
        let samples = (0..<(44_100 * 2)).map { i in Int16(12_000 * sin(2 * Double.pi * 440 * Double(i) / 44_100)) }
        let data = try Mp3Encoder.encode(samples)
        XCTAssertGreaterThan(data.count, 10_000)
        // En-tête de trame MPEG-1 couche III : synchronisation 0xFFF.
        XCTAssertEqual(data[0], 0xFF)
        XCTAssertEqual(data[1] & 0xE0, 0xE0)
        // Environ 96 kbit/s pendant 2 secondes.
        XCTAssertEqual(Double(data.count), 96_000 / 8 * 2, accuracy: 4_000)
    }

    func testM4AToMP3Conversion() throws {
        let m4a = dir.appendingPathComponent("son.m4a")
        let format = AVAudioFormat(standardFormatWithSampleRate: 48_000, channels: 1)!
        let file = try AVAudioFile(forWriting: m4a, settings: [AVFormatIDKey: kAudioFormatMPEG4AAC, AVSampleRateKey: 48_000, AVNumberOfChannelsKey: 1])
        let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 48_000)!
        buffer.frameLength = 48_000
        for i in 0..<48_000 { buffer.floatChannelData![0][i] = Float(0.3 * sin(2 * Double.pi * 330 * Double(i) / 48_000)) }
        try file.write(from: buffer)
        let mp3 = dir.appendingPathComponent("son.mp3")
        try Mp3Encoder.convert(m4a, to: mp3)
        let size = try FileManager.default.attributesOfItem(atPath: mp3.path)[.size] as? Int ?? 0
        XCTAssertGreaterThan(size, 5_000)
        let asset = AVURLAsset(url: mp3)
        XCTAssertEqual(CMTimeGetSeconds(asset.duration), 1, accuracy: 0.3)
    }

    func testToolStateProducesValidToolsAndRepairsBadSettings() {
        var state = ToolState()
        for style in PenStyle.allCases {
            state.penStyle = style
            for i in 0..<ToolState.widthCount {
                state.penWidthIndex = i
                let tool = state.pkTool as? PKInkingTool
                XCTAssertNotNil(tool)
                XCTAssertTrue(style.inkType.validWidthRange.contains(tool!.width))
            }
        }
        for kind in ToolKind.allCases {
            state.kind = kind
            XCTAssertNotNil(state.pkTool)
        }
        state.kind = .eraser
        for mode in EraserMode.allCases {
            state.eraserMode = mode
            XCTAssertTrue(state.pkTool is PKEraserTool)
        }
        state.kind = .lasso
        XCTAssertTrue(state.pkTool is PKLassoTool)

        state.penColorIndex = 99
        state.penColors = ["pas une couleur"]
        state.eraserSizeIndex = -4
        state.sanitize()
        XCTAssertEqual(state.penColors, ToolState().penColors)
        XCTAssertEqual(state.penColorIndex, state.penColors.count - 1)
        XCTAssertEqual(state.eraserSizeIndex, 0)
    }
}
