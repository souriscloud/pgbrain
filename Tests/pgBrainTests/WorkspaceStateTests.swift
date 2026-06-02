import XCTest
@testable import pgBrain

@MainActor
final class WorkspaceStateTests: XCTestCase {

    private func table(_ name: String) -> TableNode {
        TableNode(schema: "public", name: name, kind: .table, columns: [])
    }

    func testOpenTableAddsAndSelects() {
        let ws = WorkspaceState()
        ws.openTable(table("a"))
        XCTAssertEqual(ws.tabs.count, 1)
        XCTAssertEqual(ws.selectedTab?.title, "public.a")
        XCTAssertEqual(ws.selectedTab?.requestedPane, .data)
    }

    func testOpenSameTableFocusesExistingAndSetsPane() {
        let ws = WorkspaceState()
        ws.openTable(table("a"))
        ws.openTable(table("b"))
        ws.openTable(table("a"), focusPane: .structure)   // already open → focus it
        XCTAssertEqual(ws.tabs.count, 2, "no duplicate tab")
        XCTAssertEqual(ws.selectedTab?.title, "public.a")
        XCTAssertEqual(ws.selectedTab?.requestedPane, .structure)
    }

    func testOpenScratchpadIncrementsCounter() {
        let ws = WorkspaceState()
        let p1 = ws.openScratchpad()
        let p2 = ws.openScratchpad()
        XCTAssertEqual(p1.title, "Query 1")
        XCTAssertEqual(p2.title, "Query 2")
        XCTAssertEqual(ws.tabs.count, 2, "scratchpads are never deduped")
    }

    func testCloseTabReselectsNeighbourThenFallsBack() {
        let ws = WorkspaceState()
        ws.openTable(table("a")); ws.openTable(table("b")); ws.openTable(table("c"))
        let b = ws.tabs[1].id
        ws.selectedID = b
        ws.closeTab(id: b)
        XCTAssertEqual(ws.selectedTab?.title, "public.c", "selection moves to the tab now at that index")

        let cID = ws.tabs[1].id   // [a, c]
        ws.selectedID = cID
        ws.closeTab(id: cID)
        XCTAssertEqual(ws.selectedTab?.title, "public.a", "closing the last selected falls back to the end")
    }

    func testCloseTabFiresOnTabClosed() {
        let ws = WorkspaceState()
        var closed: UUID?
        ws.onTabClosed = { closed = $0 }
        ws.openTable(table("a"))
        let id = ws.tabs[0].id
        ws.closeTab(id: id)
        XCTAssertEqual(closed, id)
        ws.closeTab(id: UUID())   // unknown id → no-op
    }

    func testCloseCurrentTab() {
        let ws = WorkspaceState()
        ws.closeCurrentTab()   // empty → no-op
        ws.openTable(table("a"))
        ws.closeCurrentTab()
        XCTAssertTrue(ws.tabs.isEmpty)
    }

    func testNextAndPreviousWrapAround() {
        let ws = WorkspaceState()
        ws.nextTab(); ws.previousTab()   // empty → no-ops
        ws.openTable(table("a")); ws.openTable(table("b"))
        ws.selectedID = ws.tabs[1].id    // on b (last)
        ws.nextTab()
        XCTAssertEqual(ws.selectedTab?.title, "public.a", "next wraps to first")
        ws.previousTab()
        XCTAssertEqual(ws.selectedTab?.title, "public.b", "previous wraps to last")
    }

    func testNextWithNoSelectionStartsAtFirst() {
        let ws = WorkspaceState()
        ws.openTable(table("a")); ws.openTable(table("b"))
        ws.selectedID = nil
        ws.nextTab()
        XCTAssertEqual(ws.selectedTab?.title, "public.a")
    }

    func testSelectTabBoundsChecked() {
        let ws = WorkspaceState()
        ws.openTable(table("a")); ws.openTable(table("b"))
        ws.selectTab(at: 1)
        XCTAssertEqual(ws.selectedTab?.title, "public.b")
        ws.selectTab(at: 9)   // out of range → unchanged
        XCTAssertEqual(ws.selectedTab?.title, "public.b")
        ws.selectTab(at: -1)
        XCTAssertEqual(ws.selectedTab?.title, "public.b")
    }

    func testMoveTabBeforeTarget() {
        let ws = WorkspaceState()
        ws.openTable(table("a")); ws.openTable(table("b")); ws.openTable(table("c"))
        let a = ws.tabs[0].id, c = ws.tabs[2].id
        ws.move(id: c, before: a)
        XCTAssertEqual(ws.tabs.map(\.title), ["public.c", "public.a", "public.b"])
        ws.move(id: a, before: a)            // same → no-op
        ws.move(id: UUID(), before: a)       // missing → no-op
        XCTAssertEqual(ws.tabs.map(\.title), ["public.c", "public.a", "public.b"])
    }

    func testTabKindEquality() {
        let ws = WorkspaceState()
        let p1 = ws.openScratchpad()
        XCTAssertEqual(WorkspaceState.TabKind.table(table("a")), .table(table("a")))
        XCTAssertNotEqual(WorkspaceState.TabKind.table(table("a")), .table(table("b")))
        XCTAssertEqual(WorkspaceState.TabKind.scratchpad(p1), .scratchpad(p1))
        XCTAssertNotEqual(WorkspaceState.TabKind.scratchpad(p1), .table(table("a")))
    }
}
