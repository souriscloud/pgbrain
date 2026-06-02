import XCTest
@testable import pgBrain

// MARK: - CommandMatcher (pure)

@MainActor
final class CommandMatcherTests: XCTestCase {
    private func item(_ id: String, _ title: String, subtitle: String? = nil,
                      category: CommandItem.Category = .action) -> CommandItem {
        CommandItem(id: id, icon: "x", title: title, subtitle: subtitle, category: category, shortcut: nil, action: {})
    }

    func testCategorySortOrderIsTotalAndStable() {
        XCTAssertEqual(CommandItem.Category.action.sortOrder, 0)
        XCTAssertEqual(CommandItem.Category.allCases.count, 7)
        let orders = CommandItem.Category.allCases.map(\.sortOrder)
        XCTAssertEqual(Set(orders).count, orders.count, "sortOrder is a bijection")
    }

    func testEmptyQueryReturnsAllInCategoryThenTitleOrder() {
        let items = [
            item("a", "Zebra", category: .table),
            item("b", "Apple", category: .action),
            item("c", "Mango", category: .action),
        ]
        let out = CommandMatcher.filter(items, query: "")
        // .action (order 0) before .table (order 3); within action, alpha.
        XCTAssertEqual(out.map(\.title), ["Apple", "Mango", "Zebra"])
    }

    func testSubsequenceMatchAndPrefixWins() {
        let items = [item("a", "fundus"), item("b", "users"), item("c", "settings")]
        let out = CommandMatcher.filter(items, query: "us")
        XCTAssertEqual(out.first?.title, "users", "title-prefix beats scattered subsequence")
        XCTAssertFalse(out.contains { $0.title == "settings" }, "no subsequence → filtered out")
    }

    func testWordBoundaryBonus() {
        // Neither title contains "ut" contiguously (so no substring bonus skews
        // it); "user_total" has both letters on word boundaries, "auditor" has
        // them mid-word → boundary bonus decides.
        let out = CommandMatcher.filter([item("a", "auditor"), item("b", "user_total")], query: "ut")
        XCTAssertEqual(out.first?.title, "user_total", "word-boundary matches outrank mid-word ones")
    }

    func testOverTypedNeedleStillMatchesViaPeeling() {
        // "connections" over-types "New Connection…" — peeling trailing chars
        // keeps it matchable (≥60% of the needle used).
        let out = CommandMatcher.filter([item("a", "New Connection…")], query: "connections")
        XCTAssertEqual(out.count, 1)
    }

    func testNoMatchReturnsEmpty() {
        XCTAssertTrue(CommandMatcher.filter([item("a", "users")], query: "zzzqqq").isEmpty)
    }

    func testLimitIsRespected() {
        let items = (0..<50).map { item("id\($0)", "Item \($0)") }
        XCTAssertEqual(CommandMatcher.filter(items, query: "", limit: 10).count, 10)
    }

    func testMatchedRanges() {
        let ranges = CommandMatcher.matchedRanges(in: "users", needle: "us")
        XCTAssertEqual(ranges.count, 2)
        let title = "users"
        XCTAssertEqual(ranges.map { title[$0] }.joined(), "us")
        // No subsequence → no ranges; empty needle → no ranges.
        XCTAssertTrue(CommandMatcher.matchedRanges(in: "users", needle: "zq").isEmpty)
        XCTAssertTrue(CommandMatcher.matchedRanges(in: "users", needle: "").isEmpty)
    }
}

// MARK: - CommandProviders

@MainActor
final class CommandProvidersTests: XCTestCase {

    private func col(_ name: String, _ type: String = "integer") -> ColumnNode {
        ColumnNode(name: name, typeName: type, nullable: true, ordinal: 0)
    }

    private func richSnapshot() -> SchemaSnapshot {
        let users = TableNode(schema: "public", name: "users", kind: .table,
                              columns: [col("id"), col("geom", "geometry(Point,4326)")], primaryKey: ["id"])
        let report = TableNode(schema: "public", name: "report", kind: .view, columns: [col("n")])
        let add = FunctionNode(schema: "public", name: "add", kind: .function, arguments: "(a integer)", returnType: "integer")
        let proc = FunctionNode(schema: "public", name: "do_it", kind: .procedure, arguments: "()", returnType: "")
        let events = TableNode(schema: "analytics", name: "events", kind: .table, columns: [col("id")])
        return SchemaSnapshot(databaseName: "db", schemas: [
            SchemaNode(name: "public", tables: [users, report], functions: [add, proc]),
            SchemaNode(name: "analytics", tables: [events]),
        ])
    }

    /// Action closures that mutate global persistence / spawn UI we don't want
    /// running under `swift test`. Everything else is safe to execute
    /// (AppDelegate.shared is nil → window opens no-op; notifications post into
    /// the void; workspace/pad mutations are local to the throwaway service).
    private func isUnsafe(_ id: String) -> Bool {
        id == "scratchpad.saveCurrent"
            || id.hasPrefix("schemaadmin.vis")
            || id == "schemaadmin.showall"
            || id == "action.checkForUpdates"
            || id == "action.settings"
    }

    private func runSafeActions(_ items: [CommandItem]) {
        for item in items where !isUnsafe(item.id) { item.action() }
    }

    func testGlobalActionsWithoutService() {
        let items = CommandProviders.items(service: nil)
        let ids = Set(items.map(\.id))
        for expected in ["action.newConnection", "action.settings", "action.about",
                         "action.checkForUpdates", "action.help", "action.feedback"] {
            XCTAssertTrue(ids.contains(expected), "missing \(expected)")
        }
        runSafeActions(items)  // crash-safety + closure coverage for the safe ones
    }

    func testTableSelectedScenario() {
        let service = ConnectionService(connection: Connection(name: "t", database: "db"))
        let snap = richSnapshot()
        service.injectSchemaForTests(snap, postgis: "3.4")
        let users = snap.schemas[0].tables[0]
        service.workspace.openTable(users)   // selects it

        let items = CommandProviders.items(service: service)
        let ids = Set(items.map(\.id))

        // Front-table contextual actions (it's a real table).
        XCTAssertTrue(ids.contains("fronttable.structure"))
        XCTAssertTrue(ids.contains("fronttable.ddl"))
        XCTAssertTrue(ids.contains("fronttable.findUsages"))
        XCTAssertTrue(ids.contains("fronttable.newIndex"))
        XCTAssertTrue(ids.contains { $0.hasPrefix("fronttable.export.") })
        XCTAssertTrue(ids.contains { $0.hasPrefix("fronttable.maint.") })
        // View modes incl. Map (geometry column + PostGIS) + edit-structure.
        XCTAssertTrue(ids.contains("viewmode.grid"))
        XCTAssertTrue(ids.contains("viewmode.form"))
        XCTAssertTrue(ids.contains("viewmode.map"))
        XCTAssertTrue(ids.contains("action.editStructure"))
        // Schema/table/function/erd lists.
        XCTAssertTrue(ids.contains("table.public.users"))
        XCTAssertTrue(ids.contains("table.analytics.events"))
        XCTAssertTrue(ids.contains("erd.public"))
        XCTAssertTrue(ids.contains("schemaadmin.rename.public"))
        XCTAssertTrue(ids.contains { $0.hasPrefix("function.public.add") })
        XCTAssertTrue(ids.contains { $0.hasPrefix("pgdump.") })
        // A tab exists now.
        XCTAssertTrue(ids.contains { $0.hasPrefix("tab.") })

        runSafeActions(items)
    }

    func testScratchpadSelectedScenario() {
        let service = ConnectionService(connection: Connection(name: "t", database: "db"))
        service.injectSchemaForTests(richSnapshot())
        let pad = service.workspace.openScratchpad()   // selects it
        pad.cells.first(where: { $0.kind == .sql })?.text = "SELECT 1"

        let items = CommandProviders.items(service: service)
        let ids = Set(items.map(\.id))

        // Scratchpad-context items.
        XCTAssertTrue(ids.contains("scratchpad.saveCurrent"), "non-empty pad → save offered")
        XCTAssertTrue(ids.contains("schema.reset"))
        XCTAssertTrue(ids.contains("schema.set.public"))
        XCTAssertTrue(ids.contains("action.renameTab"))
        XCTAssertTrue(ids.contains("action.colorTab"))
        // No front-table actions when a scratchpad is front.
        XCTAssertFalse(ids.contains("fronttable.structure"))

        runSafeActions(items)
    }

    func testViewTabHasNoTableOnlyActions() {
        let service = ConnectionService(connection: Connection(name: "t", database: "db"))
        let snap = richSnapshot()
        service.injectSchemaForTests(snap)
        let report = snap.schemas[0].tables[1]   // the view
        service.workspace.openTable(report)

        let ids = Set(CommandProviders.items(service: service).map(\.id))
        // Views still get structure/ddl/export, but not table-only mutations.
        XCTAssertTrue(ids.contains("fronttable.structure"))
        XCTAssertFalse(ids.contains("fronttable.newIndex"))
        XCTAssertFalse(ids.contains("action.editStructure"))
        XCTAssertFalse(ids.contains("viewmode.map"), "no PostGIS injected")
    }
}
