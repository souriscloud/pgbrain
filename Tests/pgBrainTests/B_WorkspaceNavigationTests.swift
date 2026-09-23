import XCTest
@testable import pgBrain

@MainActor
final class B_WorkspaceNavigationTests: XCTestCase {

    private func t(_ name: String, schema: String = "public", oid: Int = 0) -> TableNode {
        var node = TableNode(schema: schema, name: name, kind: .table, columns: [])
        node.oid = oid
        return node
    }

    private func titles(_ ws: WorkspaceState) -> [String] { ws.tabs.map(\.title) }

    // MARK: Preview tabs

    func testPreviewReplacesPreviousPreview() {
        let ws = WorkspaceState()
        ws.openTable(t("a"), preview: true)
        let firstID = ws.tabs[0].id
        var closed: [UUID] = []
        ws.onTabClosed = { closed.append($0) }
        ws.openTable(t("b"), preview: true)
        XCTAssertEqual(titles(ws), ["public.b"], "one preview tab per window")
        XCTAssertTrue(ws.selectedTab?.isPreview ?? false)
        XCTAssertEqual(closed, [firstID], "replaced preview releases its loader cache")
    }

    func testExplicitOpenPinsPreview() {
        let ws = WorkspaceState()
        ws.openTable(t("a"), preview: true)
        ws.openTable(t("a"))
        XCTAssertFalse(ws.tabs[0].isPreview)
        ws.openTable(t("b"), preview: true)
        XCTAssertEqual(titles(ws), ["public.a", "public.b"], "kept tab isn't replaced")
    }

    func testEditingOrFilteringPinsPreview() {
        let ws = WorkspaceState()
        ws.openTable(t("a"), preview: true)
        ws.tabs[0].hasPendingChanges = true
        XCTAssertFalse(ws.tabs[0].isPreview)

        ws.openTable(t("b"), preview: true)
        ws.selectedTab?.tableWhereClause = "id = 1"
        XCTAssertFalse(ws.selectedTab?.isPreview ?? true)
    }

    func testPreviewOfOpenTableFocusesWithoutDemoting() {
        let ws = WorkspaceState()
        ws.openTable(t("a"))
        ws.openTable(t("b"))
        ws.openTable(t("a"), preview: true)
        XCTAssertEqual(ws.tabs.count, 2)
        XCTAssertEqual(ws.selectedTab?.title, "public.a")
        XCTAssertFalse(ws.tabs[0].isPreview)
    }

    func testOnTableOpenedFires() {
        let ws = WorkspaceState()
        var opened: [String] = []
        ws.onTableOpened = { opened.append($0.id) }
        ws.openTable(t("a"), preview: true)
        ws.openTable(t("a"))
        XCTAssertEqual(opened, ["public.a", "public.a"])
    }

    // MARK: Close others / right / all, pinning

    func testBulkCloseTargetsSkipPinned() {
        let ws = WorkspaceState()
        for n in ["a", "b", "c", "d"] { ws.openTable(t(n)) }
        let ids = ws.tabs.map(\.id)
        ws.togglePinned(id: ids[2])   // pin c → moves to front
        XCTAssertEqual(titles(ws), ["public.c", "public.a", "public.b", "public.d"])
        XCTAssertTrue(ws.tabs[0].isPinned)

        XCTAssertEqual(Set(ws.idsToCloseOthers(keeping: ids[1])), [ids[0], ids[3]])
        XCTAssertEqual(ws.idsToCloseRight(of: ids[0]), [ids[1], ids[3]])
        XCTAssertEqual(Set(ws.idsToCloseAll()), [ids[0], ids[1], ids[3]])

        ws.closeTabs(ws.idsToCloseAll())
        XCTAssertEqual(titles(ws), ["public.c"])

        ws.togglePinned(id: ids[2])
        XCTAssertFalse(ws.tabs[0].isPinned)
    }

    func testDirtyTabsDetection() {
        let ws = WorkspaceState()
        ws.openTable(t("a")); ws.openTable(t("b"))
        ws.tabs[1].hasPendingChanges = true
        XCTAssertEqual(ws.dirtyTabs(among: ws.tabs.map(\.id)).map(\.title), ["public.b"])
        XCTAssertTrue(ws.dirtyTabs(among: [ws.tabs[0].id]).isEmpty)
    }

    func testDisplayTitleShortUnlessCollision() {
        let ws = WorkspaceState()
        ws.openTable(t("users"))
        XCTAssertEqual(ws.displayTitle(for: ws.tabs[0]), "users")
        ws.openTable(t("users", schema: "sales"))
        XCTAssertEqual(ws.displayTitle(for: ws.tabs[0]), "public.users")
        XCTAssertEqual(ws.displayTitle(for: ws.tabs[1]), "sales.users")
        ws.tabs[0].title = "Prod users"
        XCTAssertEqual(ws.displayTitle(for: ws.tabs[0]), "Prod users", "custom titles win")
    }

    // MARK: Back / forward

    func testBackForwardOverTabSwitches() {
        let ws = WorkspaceState()
        ws.openTable(t("a")); ws.openTable(t("b")); ws.openTable(t("c"))
        XCTAssertTrue(ws.canGoBack)
        ws.goBack()
        XCTAssertEqual(ws.selectedTab?.title, "public.b")
        ws.goBack()
        XCTAssertEqual(ws.selectedTab?.title, "public.a")
        XCTAssertFalse(ws.canGoBack)
        ws.goForward()
        XCTAssertEqual(ws.selectedTab?.title, "public.b")
        ws.goForward()
        XCTAssertEqual(ws.selectedTab?.title, "public.c")
        XCTAssertFalse(ws.canGoForward)
    }

    func testNewNavigationClearsForward() {
        let ws = WorkspaceState()
        ws.openTable(t("a")); ws.openTable(t("b"))
        ws.goBack()
        XCTAssertTrue(ws.canGoForward)
        ws.openTable(t("c"))
        XCTAssertFalse(ws.canGoForward)
    }

    func testClosedTabsAreSkipped() {
        let ws = WorkspaceState()
        ws.openTable(t("a")); ws.openTable(t("b")); ws.openTable(t("c"))
        ws.closeTab(id: ws.tabs[1].id)   // drop b
        ws.goBack()
        XCTAssertEqual(ws.selectedTab?.title, "public.a")
    }

    func testNavigateCarriesWhereClauseAndBackRestoresIt() {
        let ws = WorkspaceState()
        ws.openTable(t("orders"))
        let customers = t("customers")
        let target = ws.navigate(toTable: customers, where: "\"id\" = 5")
        XCTAssertEqual(target.tableWhereClause, "\"id\" = 5")
        XCTAssertFalse(target.requestedFilterReload, "fresh tab reads its WHERE on first load")

        // Second FK jump into the already-open tab.
        ws.selectedID = ws.tabs[0].id
        let again = ws.navigate(toTable: customers, where: "\"id\" = 7")
        XCTAssertTrue(again === target)
        XCTAssertTrue(again.requestedFilterReload)
        again.requestedFilterReload = false

        ws.goBack()
        XCTAssertEqual(ws.selectedTab?.title, "public.orders")
        ws.goForward()
        XCTAssertEqual(ws.selectedTab?.tableWhereClause, "\"id\" = 7")
    }

    func testSelfNavigationRestoresPreviousFilter() {
        let ws = WorkspaceState()
        let emp = t("employees")
        ws.openTable(emp)
        ws.selectedTab?.tableWhereClause = "\"dept\" = 3"
        ws.navigate(toTable: emp, where: "\"id\" = 42")   // manager_id → id on the same table
        XCTAssertEqual(ws.selectedTab?.tableWhereClause, "\"id\" = 42")
        ws.goBack()
        XCTAssertEqual(ws.selectedTab?.tableWhereClause, "\"dept\" = 3")
        XCTAssertTrue(ws.selectedTab?.requestedFilterReload ?? false)
    }

    // MARK: Reconcile after schema reload

    func testReconcileRenamedDroppedAndRefreshed() {
        let ws = WorkspaceState()
        ws.openTable(t("keep", oid: 1))
        ws.openTable(t("old_name", oid: 2))
        ws.openTable(t("gone", oid: 3))
        ws.openTable(t("gone_preview", oid: 4), preview: true)
        let renamedTabID = ws.tabs[1].id
        ws.tabs[1].tableWhereClause = "x > 1"
        var closed: [UUID] = []
        ws.onTabClosed = { closed.append($0) }

        var keep = t("keep", oid: 1)
        keep.primaryKey = ["id"]
        let fresh = snap([SchemaNode(name: "public", tables: [keep, t("new_name", oid: 2)])])
        let result = ws.reconcile(with: fresh)

        XCTAssertEqual(result.renamed.map(\.to), ["public.new_name"])
        XCTAssertEqual(result.dropped, ["public.gone", "public.gone_preview"])
        XCTAssertEqual(titles(ws), ["public.keep", "public.new_name", "public.gone"])
        XCTAssertEqual(ws.tabs[0].tableNode?.primaryKey, ["id"], "live node swapped in")
        XCTAssertEqual(ws.tabs[1].tableWhereClause, "x > 1")
        XCTAssertNotEqual(ws.tabs[1].id, renamedTabID, "renamed tab is a fresh tab so its loader resets")
        XCTAssertTrue(closed.contains(renamedTabID))
        XCTAssertTrue(ws.tabs[2].isStale)

        // Re-running doesn't re-report the same drop.
        XCTAssertTrue(ws.reconcile(with: fresh).dropped.isEmpty)
        XCTAssertTrue(ws.reconcile(with: .empty).renamed.isEmpty, "empty snapshot (loading) is ignored")
        XCTAssertTrue(ws.tabs[2].isStale)
    }

    func testScratchpadSearchPathOverride() {
        let ws = WorkspaceState()
        ws.defaultSearchPath = "app"
        XCTAssertEqual(ws.openScratchpad().searchPath, "app")
        XCTAssertEqual(ws.openScratchpad(searchPath: "reporting").searchPath, "reporting")
        ws.defaultSearchPath = ""
        XCTAssertNil(ws.openScratchpad().searchPath)
    }
}

private func snap(_ schemas: [SchemaNode]) -> SchemaSnapshot {
    SchemaSnapshot(databaseName: "db", schemas: schemas)
}

// MARK: - Session persistence of the new fields

@MainActor
final class B_SessionNavigationTests: XCTestCase {

    func testNewWindowAndTabFieldsRoundTrip() throws {
        let ws = WorkspaceState()
        ws.openTable(TableNode(schema: "public", name: "a", kind: .table, columns: []))
        ws.openTable(TableNode(schema: "public", name: "b", kind: .table, columns: []), preview: true)
        ws.togglePinned(id: ws.tabs[0].id)
        ws.sidebarVisible = false
        ws.sidebarFilter = "ord"
        ws.sidebarIncludeColumns = true
        ws.expandedSidebarNodes = ["schema:public", "section:recent"]

        let state = SessionStateStore.makeSnapshot(windows: [
            SessionStateStore.WindowInput(connectionID: UUID(), frame: .zero, workspace: ws, database: "analytics")
        ])
        let decoded = try JSONDecoder().decode(SessionState.self, from: JSONEncoder().encode(state))
        let win = try XCTUnwrap(decoded.windows.first)
        XCTAssertEqual(win.database, "analytics")
        XCTAssertEqual(win.sidebarVisible, false)
        XCTAssertEqual(win.sidebarFilter, "ord")
        XCTAssertEqual(win.sidebarIncludeColumns, true)
        XCTAssertEqual(win.expandedSidebarNodes, ["schema:public", "section:recent"])
        XCTAssertEqual(win.tabs[0].isPinned, true)
        XCTAssertEqual(win.tabs[1].isPreview, true)
        XCTAssertNil(win.tabs[0].isPreview)
    }

    func testOldSnapshotWithoutNewFieldsDecodes() throws {
        let json = """
        {"version":1,"savedAt":0,"windows":[{"connectionID":"\(UUID().uuidString)",
        "frame":{"x":0,"y":0,"w":10,"h":10},"tabs":[{"kind":"table","tableSchema":"public","tableName":"a"}]}]}
        """
        let state = try JSONDecoder().decode(SessionState.self, from: Data(json.utf8))
        XCTAssertNil(state.windows[0].database)
        XCTAssertNil(state.windows[0].expandedSidebarNodes)
        XCTAssertNil(state.windows[0].tabs[0].isPreview)
    }

    func testDefaultDatabaseIsNotRecorded() {
        let state = SessionStateStore.makeSnapshot(windows: [
            SessionStateStore.WindowInput(connectionID: UUID(), frame: .zero, workspace: WorkspaceState())
        ])
        XCTAssertNil(state.windows[0].database)
        XCTAssertNil(state.windows[0].expandedSidebarNodes, "untouched expansion stays nil → first-connect default")
    }
}

// MARK: - Recents / pinned store

@MainActor
final class B_NavigationHistoryStoreTests: XCTestCase {

    private func tempURL() -> URL {
        FileManager.default.temporaryDirectory.appendingPathComponent("pgb-nav-\(UUID().uuidString).json")
    }

    func testRecentsOrderDedupeAndCap() {
        let store = NavigationHistoryStore(testURL: tempURL())
        let scope = NavigationHistoryStore.Scope(connectionID: UUID(), database: "db")
        store.recordOpen("public.a", scope: scope)
        store.recordOpen("public.b", scope: scope)
        store.recordOpen("public.a", scope: scope)
        XCTAssertEqual(store.recents(for: scope), ["public.a", "public.b"])
        for i in 0..<30 { store.recordOpen("public.t\(i)", scope: scope) }
        XCTAssertEqual(store.recents(for: scope).count, NavigationHistoryStore.recentLimit)
        XCTAssertEqual(store.recents(for: scope).first, "public.t29")
    }

    func testScopesAreIsolatedPerDatabase() {
        let store = NavigationHistoryStore(testURL: tempURL())
        let id = UUID()
        let a = NavigationHistoryStore.Scope(connectionID: id, database: "one")
        let b = NavigationHistoryStore.Scope(connectionID: id, database: "two")
        store.setPinned(true, tableID: "public.x", scope: a)
        XCTAssertTrue(store.isPinned("public.x", scope: a))
        XCTAssertFalse(store.isPinned("public.x", scope: b))
    }

    func testPersistsAcrossInstances() {
        let url = tempURL()
        defer { try? FileManager.default.removeItem(at: url) }
        let scope = NavigationHistoryStore.Scope(connectionID: UUID(), database: "db")
        let store = NavigationHistoryStore(testURL: url)
        store.togglePinned("public.a", scope: scope)
        store.recordOpen("public.b", scope: scope)
        store.flushNowForTests()
        let reloaded = NavigationHistoryStore(testURL: url)
        XCTAssertEqual(reloaded.pinned(for: scope), ["public.a"])
        XCTAssertEqual(reloaded.recents(for: scope), ["public.b"])
        reloaded.togglePinned("public.a", scope: scope)
        XCTAssertTrue(reloaded.pinned(for: scope).isEmpty)
        reloaded.clearRecents(scope: scope)
        XCTAssertTrue(reloaded.recents(for: scope).isEmpty)
    }
}
