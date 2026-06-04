import XCTest
@testable import pgBrain

/// Covers `SessionStateStore.makeSnapshot` — the pure window→`SessionState`
/// flattening that was historically the crashiest path in the app (the
/// v0.0.3 isolation crash lived in the `snapshotAndPersist` it was extracted
/// from). Driving it directly, without a live `AppDelegate`/`NSWindow`, is the
/// no-`.xcodeproj`-friendly way to lock the behaviour down.
@MainActor
final class SessionSnapshotTests: XCTestCase {

    private func table(_ schema: String, _ name: String) -> TableNode {
        TableNode(schema: schema, name: name, kind: .table, columns: [])
    }

    private func input(_ ws: WorkspaceState,
                       id: UUID = UUID(),
                       frame: NSRect = NSRect(x: 10, y: 20, width: 800, height: 600))
        -> SessionStateStore.WindowInput {
        SessionStateStore.WindowInput(connectionID: id, frame: frame, workspace: ws)
    }

    func testEmptyWindowsProduceEmptyState() {
        let state = SessionStateStore.makeSnapshot(windows: [])
        XCTAssertTrue(state.windows.isEmpty)
    }

    func testTableAndScratchpadTabsAreCaptured() {
        let ws = WorkspaceState()
        ws.openTable(table("public", "users"))
        ws.tabs[0].tableWhereClause = "id > 5"
        ws.tabs[0].tableOrderByClause = "id desc"
        let pad = ws.openScratchpad()
        pad.searchPath = "analytics"
        ws.selectedID = ws.tabs[1].id   // select the scratchpad

        let connID = UUID()
        let frame = NSRect(x: 5, y: 7, width: 1024, height: 768)
        let state = SessionStateStore.makeSnapshot(windows: [input(ws, id: connID, frame: frame)])

        XCTAssertEqual(state.windows.count, 1)
        let win = state.windows[0]
        XCTAssertEqual(win.connectionID, connID)
        XCTAssertEqual(win.frame.ns, frame, "frame round-trips through CodableRect")
        XCTAssertEqual(win.selectedTabIndex, 1, "selected scratchpad is index 1")
        XCTAssertEqual(win.tabs.count, 2)

        let t = win.tabs[0]
        XCTAssertEqual(t.kind, .table)
        XCTAssertEqual(t.tableSchema, "public")
        XCTAssertEqual(t.tableName, "users")
        XCTAssertEqual(t.tableWhereClause, "id > 5")
        XCTAssertEqual(t.tableOrderByClause, "id desc")

        let s = win.tabs[1]
        XCTAssertEqual(s.kind, .scratchpad)
        XCTAssertEqual(s.scratchpadTitle, pad.title)
        XCTAssertEqual(s.scratchpadSearchPath, "analytics")
        XCTAssertNil(s.tabTitle, "un-renamed scratchpad tab carries no override title")
    }

    func testEmptyClausesCollapseToNil() {
        let ws = WorkspaceState()
        ws.openTable(table("public", "t"))   // no WHERE / ORDER BY set
        let state = SessionStateStore.makeSnapshot(windows: [input(ws)])
        let tab = state.windows[0].tabs[0]
        XCTAssertNil(tab.tableWhereClause, "empty WHERE serialises as nil, not \"\"")
        XCTAssertNil(tab.tableOrderByClause)
    }

    func testNoSelectionYieldsNilIndex() {
        let ws = WorkspaceState()
        ws.openTable(table("public", "a"))
        ws.selectedID = UUID()   // an id not in the tab list
        let state = SessionStateStore.makeSnapshot(windows: [input(ws)])
        XCTAssertNil(state.windows[0].selectedTabIndex)
    }

    func testMultipleWindowsPreserveOrder() {
        let ws1 = WorkspaceState(); ws1.openTable(table("public", "one"))
        let ws2 = WorkspaceState(); ws2.openTable(table("public", "two"))
        let state = SessionStateStore.makeSnapshot(windows: [input(ws1), input(ws2)])
        XCTAssertEqual(state.windows.map { $0.tabs[0].tableName }, ["one", "two"])
    }

    /// The snapshot must survive a JSON round-trip — this is what actually
    /// lands on disk and gets restored on next launch.
    func testSnapshotEncodesAndDecodes() throws {
        let ws = WorkspaceState()
        ws.openTable(table("sales", "orders"))
        _ = ws.openScratchpad()
        let state = SessionStateStore.makeSnapshot(windows: [input(ws)])
        let data = try JSONEncoder().encode(state)
        let back = try JSONDecoder().decode(SessionState.self, from: data)
        XCTAssertEqual(back.windows.count, 1)
        XCTAssertEqual(back.windows[0].tabs.count, 2)
        XCTAssertEqual(back.windows[0].tabs[0].tableName, "orders")
    }
}
