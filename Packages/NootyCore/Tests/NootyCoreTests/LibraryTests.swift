import XCTest
@testable import NootyCore

final class LibraryTests: XCTestCase {
    private func folder(_ title: String, in parent: UUID? = nil, at t: Double = 0) -> LibraryEntry {
        LibraryEntry(kind: .folder, parentID: parent, title: title, createdAt: t)
    }

    private func notebook(_ title: String, in parent: UUID? = nil, at t: Double = 0) -> LibraryEntry {
        LibraryEntry(kind: .notebook, parentID: parent, title: title, createdAt: t)
    }

    func testChildrenAreScopedSortedAndFoldersFirst() {
        let droit = folder("Droit")
        var index = LibraryIndex()
        index.add(notebook("Cours 10", at: 3))
        index.add(notebook("cours 2", at: 5))
        index.add(droit)
        index.add(notebook("Foncier", in: droit.id, at: 9))
        XCTAssertEqual(index.children(of: nil, sort: .name).map(\.title), ["Droit", "cours 2", "Cours 10"])
        XCTAssertEqual(index.children(of: nil, sort: .created).map(\.title), ["Droit", "cours 2", "Cours 10"])
        XCTAssertEqual(index.children(of: droit.id).map(\.title), ["Foncier"])
    }

    func testModifiedSortPutsRecentFirst() {
        let a = notebook("A", at: 1), b = notebook("B", at: 2)
        var index = LibraryIndex(items: [a, b])
        index.touch(a.id, now: 50)
        XCTAssertEqual(index.children(of: nil, sort: .modified).map(\.title), ["A", "B"])
    }

    func testTrashHidesFolderContentAndRestoreBringsItBack() {
        let dossier = folder("Dossier")
        let note = notebook("Note", in: dossier.id)
        var index = LibraryIndex(items: [dossier, note])
        index.setFavorite(note.id, true)
        index.trash(dossier.id, now: 10)
        XCTAssertTrue(index.children(of: nil).isEmpty)
        XCTAssertTrue(index.favorites().isEmpty, "un favori dans un dossier à la corbeille n’est plus listé")
        XCTAssertEqual(index.trashed().map(\.id), [dossier.id])
        XCTAssertTrue(index.isEffectivelyTrashed(note.id))
        index.restore(dossier.id)
        XCTAssertEqual(index.children(of: dossier.id).map(\.id), [note.id])
        XCTAssertEqual(index.favorites().map(\.id), [note.id])
    }

    func testRestoreGoesToRootWhenOriginalFolderIsGone() {
        let dossier = folder("Dossier")
        let note = notebook("Note", in: dossier.id)
        var index = LibraryIndex(items: [dossier, note])
        index.trash(note.id, now: 1)
        index.trash(dossier.id, now: 2)
        index.restore(note.id)
        XCTAssertNil(index.item(note.id)?.parentID)
        XCTAssertEqual(index.children(of: nil).map(\.id), [note.id])
    }

    func testPermanentDeleteRemovesDescendantsAndReportsNotebooks() {
        let a = folder("A")
        let b = folder("B", in: a.id)
        let n1 = notebook("N1", in: b.id), n2 = notebook("N2", in: a.id), keep = notebook("Garde")
        var index = LibraryIndex(items: [a, b, n1, n2, keep])
        XCTAssertEqual(Set(index.deletePermanently(a.id)), [n1.id, n2.id])
        XCTAssertEqual(index.items.map(\.id), [keep.id])
    }

    func testMoveRejectsCyclesAndNonFolders() {
        let a = folder("A")
        let b = folder("B", in: a.id)
        let n = notebook("N")
        var index = LibraryIndex(items: [a, b, n])
        XCTAssertFalse(index.move(a.id, to: b.id, now: 1), "un dossier ne va pas dans son descendant")
        XCTAssertFalse(index.move(a.id, to: a.id, now: 1))
        XCTAssertFalse(index.move(a.id, to: n.id, now: 1), "un carnet n’est pas une destination")
        XCTAssertTrue(index.move(n.id, to: b.id, now: 1))
        XCTAssertEqual(index.ancestors(of: n.id).map(\.title), ["A", "B"])
        XCTAssertTrue(index.move(n.id, to: nil, now: 2))
        XCTAssertEqual(index.moveTargets(for: a.id).map(\.title), [])
        XCTAssertEqual(index.moveTargets(for: n.id).map(\.title), ["A", "B"])
    }

    func testTitlesAreNormalizedAndMadeUnique() {
        XCTAssertEqual(LibraryIndex.normalizedTitle("  Droit \n  foncier  "), "Droit foncier")
        XCTAssertNil(LibraryIndex.normalizedTitle("   \n"))
        XCTAssertEqual(LibraryIndex.normalizedTitle(String(repeating: "a", count: 500))?.count, LibraryIndex.maxTitleLength)
        var index = LibraryIndex(items: [notebook("Sans titre"), notebook("sans titre 2")])
        XCTAssertEqual(index.uniqueTitle("Sans titre", in: nil), "Sans titre 3")
        XCTAssertEqual(index.uniqueTitle("Autre", in: nil), "Autre")
        let id = index.items[0].id
        XCTAssertFalse(index.rename(id, to: "  ", now: 1))
        XCTAssertTrue(index.rename(id, to: " Cours  1 ", now: 7))
        XCTAssertEqual(index.item(id)?.title, "Cours 1")
        XCTAssertEqual(index.item(id)?.updatedAt, 7)
    }

    func testDuplicateIDsAreRefusedOnAdd() {
        let n = notebook("N")
        var index = LibraryIndex(items: [n])
        XCTAssertFalse(index.add(n))
        XCTAssertEqual(index.items.count, 1)
    }

    func testRepairBreaksCyclesAndDanglingParents() {
        var a = folder("A"), b = folder("B")
        a.parentID = b.id
        b.parentID = a.id
        var orphan = notebook("Orphelin")
        orphan.parentID = UUID()
        let index = LibraryIndex(items: [a, b, orphan])
        XCTAssertNil(index.item(orphan.id)?.parentID)
        XCTAssertTrue(index.items.contains { $0.kind == .folder && $0.parentID == nil })
        XCTAssertEqual(index.descendants(of: a.id).count <= 1, true)
    }

    func testCodecRoundTripAndRejections() throws {
        let dossier = folder("Dossier", at: 5)
        var note = notebook("Note é", in: dossier.id, at: 6)
        note.favorite = true
        note.trashedAt = 9
        note.color = RGBA(hex: "#C2500F")!
        let index = LibraryIndex(items: [dossier, note])
        let data = try LibraryCodec.encode(index)
        XCTAssertEqual(try LibraryCodec.decode(data), index)

        var json = try JSONSerialization.jsonObject(with: data) as! [String: Any]
        var items = json["items"] as! [[String: Any]]
        items[1]["id"] = items[0]["id"]
        json["items"] = items
        XCTAssertThrowsError(try LibraryCodec.decode(try JSONSerialization.data(withJSONObject: json)))
        XCTAssertThrowsError(try LibraryCodec.decode(try PageCodec.encode(Page.a4(updatedAt: 0)))) {
            XCTAssertEqual($0 as? FormatError, .notNooty)
        }
    }
}
