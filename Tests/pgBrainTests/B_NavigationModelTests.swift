import XCTest
@testable import pgBrain

private func tbl(_ schema: String, _ name: String, kind: TableNode.Kind = .table,
                 columns: [String] = [], oid: Int = 0, partitionOf: String? = nil,
                 ext: Bool = false) -> TableNode {
    var t = TableNode(schema: schema, name: name, kind: kind,
                      columns: columns.enumerated().map {
                          ColumnNode(name: $0.element, typeName: "integer", nullable: true, ordinal: $0.offset + 1)
                      })
    t.oid = oid
    t.partitionOf = partitionOf
    t.isExtensionOwned = ext
    return t
}

private func snap(_ schemas: [SchemaNode]) -> SchemaSnapshot {
    SchemaSnapshot(databaseName: "db", schemas: schemas)
}

// MARK: - Sidebar rebuild decision + tree shape

@MainActor
final class B_SidebarTreeTests: XCTestCase {

    private func content(_ s: SchemaSnapshot) -> SidebarContent { SidebarContent(snapshot: s) }
    private let noFilter = SidebarFilterKey(term: "", includeColumns: false)

    func testIdenticalInputsDoNothing() {
        let s = snap([SchemaNode(name: "public", tables: [tbl("public", "a")])])
        XCTAssertEqual(SidebarTree.update(oldContent: content(s), oldFilter: noFilter,
                                          newContent: content(s), newFilter: noFilter), .none)
    }

    func testFirstApplyRebuilds() {
        let s = snap([SchemaNode(name: "public", tables: [tbl("public", "a")])])
        XCTAssertEqual(SidebarTree.update(oldContent: nil, oldFilter: nil,
                                          newContent: content(s), newFilter: noFilter), .rebuild)
    }

    func testColumnEnrichmentRebuildsEvenWithSameTableCount() {
        let shallow = snap([SchemaNode(name: "public", tables: [tbl("public", "a")])])
        let enriched = shallow.merging(columns: ["public\u{1F}a": [ColumnNode(name: "id", typeName: "int", nullable: false, ordinal: 1)]])
        XCTAssertEqual(SidebarTree.update(oldContent: content(shallow), oldFilter: noFilter,
                                          newContent: content(enriched), newFilter: noFilter), .rebuild,
                       "phase-2 columns must reach the tree")
    }

    func testHidingFunctionsOnlySchemaRebuilds() {
        let fn = FunctionNode(schema: "util", name: "f", kind: .function, arguments: "()", returnType: "int")
        let before = snap([SchemaNode(name: "public", tables: [tbl("public", "a")]),
                           SchemaNode(name: "util", tables: [], functions: [fn])])
        let after = snap([SchemaNode(name: "public", tables: [tbl("public", "a")])])
        XCTAssertEqual(SidebarTree.update(oldContent: content(before), oldFilter: noFilter,
                                          newContent: content(after), newFilter: noFilter), .rebuild)
    }

    func testFilterChangeOnlyRefilters() {
        let s = snap([SchemaNode(name: "public", tables: [tbl("public", "a")])])
        XCTAssertEqual(SidebarTree.update(oldContent: content(s), oldFilter: noFilter,
                                          newContent: content(s),
                                          newFilter: SidebarFilterKey(term: "a", includeColumns: false)), .refilter)
    }

    func testRecentsOrPinsChangeRebuilds() {
        let s = snap([SchemaNode(name: "public", tables: [tbl("public", "a")])])
        var pinned = content(s)
        pinned.pinned = ["public.a"]
        XCTAssertEqual(SidebarTree.update(oldContent: content(s), oldFilter: noFilter,
                                          newContent: pinned, newFilter: noFilter), .rebuild)
    }

    func testBuildNestsPartitionsAndKeepsEmptySchemas() {
        let s = snap([
            SchemaNode(name: "empty", tables: []),
            SchemaNode(name: "public", tables: [
                tbl("public", "events", oid: 1),
                tbl("public", "events_2025", oid: 2, partitionOf: "public.events"),
                tbl("public", "users", oid: 3),
            ]),
        ])
        let built = SidebarTree.build(content(s))
        XCTAssertEqual(built.roots.map(\.id), ["schema:empty", "schema:public"])
        XCTAssertEqual(built.roots[0].secondary, "empty")
        let publicKids = built.roots[1].children.map(\.id)
        XCTAssertEqual(publicKids, ["table:public.events", "table:public.users"], "partition is not top-level")
        let partitions = built.nodesByID["partitions:public.events"]
        XCTAssertEqual(partitions?.children.map(\.id), ["table:public.events_2025"])
        XCTAssertTrue(built.nodesByID["table:public.events_2025"]?.parent === partitions)
    }

    func testExtensionObjectsHiddenByDefault() {
        let fn = FunctionNode(schema: "public", name: "st_area", kind: .function, arguments: "(geometry)",
                              returnType: "double precision", isExtensionOwned: true)
        let s = snap([SchemaNode(name: "public",
                                 tables: [tbl("public", "users"), tbl("public", "spatial_ref_sys", ext: true)],
                                 functions: [fn])])
        let hidden = SidebarTree.build(content(s))
        XCTAssertEqual(hidden.roots[0].children.map(\.id), ["table:public.users"])
        var shown = content(s)
        shown.showExtensionObjects = true
        let all = SidebarTree.build(shown)
        XCTAssertEqual(all.roots[0].children.map(\.id),
                       ["table:public.users", "table:public.spatial_ref_sys", "functions:public"])
    }

    func testSectionsResolveAgainstSnapshotAndSkipMissing() {
        let s = snap([SchemaNode(name: "public", tables: [tbl("public", "a"), tbl("public", "b")])])
        var c = content(s)
        c.pinned = ["public.b", "public.gone"]
        c.recents = ["public.a", "public.b"]
        let built = SidebarTree.build(c)
        XCTAssertEqual(built.roots.map(\.id), ["section:pinned", "section:recent", "schema:public"])
        XCTAssertEqual(built.roots[0].children.map(\.id), ["pinned/table:public.b"])
        XCTAssertEqual(built.roots[1].children.map(\.id), ["recent/table:public.a"], "pinned rows aren't repeated in recents")
        XCTAssertEqual(built.roots[0].children[0].secondary, "public", "section rows show their schema")
    }

    func testColumnsAreLazyAndStable() {
        let s = snap([SchemaNode(name: "public", tables: [tbl("public", "a", columns: ["id", "name"])])])
        let built = SidebarTree.build(content(s))
        let group = built.roots[0].children[0].children[0]
        XCTAssertEqual(group.id, "columns:public.a")
        XCTAssertTrue(group.isExpandable)
        XCTAssertEqual(group.children.map(\.displayName), ["id", "name"])
    }

    func testFilteredTreeUsesRealSchemasNotSyntheticRoot() {
        let s = snap([
            SchemaNode(name: "public", tables: [tbl("public", "users"), tbl("public", "orders")]),
            SchemaNode(name: "sales", tables: [tbl("sales", "user_totals")]),
        ])
        let index = SchemaIndex(snapshot: s)
        let built = SidebarTree.buildFiltered(index: index, filter: SidebarFilterKey(term: "usr", includeColumns: false),
                                              showExtensionObjects: false)
        XCTAssertEqual(built.roots.map(\.id), ["filter/schema:public", "filter/schema:sales"])
        XCTAssertEqual(built.roots[0].children.map(\.displayName), ["users"])
        XCTAssertEqual(built.roots[1].countBadge, 1)
        guard case .schema = built.roots[0].kind else { return XCTFail("schema rows, not a database root") }
    }

    func testDefaultExpansionCollapsesWhenManySchemas() {
        let few = snap([SchemaNode(name: "a", tables: [tbl("a", "t")]), SchemaNode(name: "public", tables: [tbl("public", "t")])])
        XCTAssertTrue(SidebarTree.defaultExpansion(for: few, preferredSchema: nil).isSuperset(of: ["schema:a", "schema:public"]))
        let many = snap(["a", "b", "c", "d", "public"].map { SchemaNode(name: $0, tables: [tbl($0, "t")]) })
        let exp = SidebarTree.defaultExpansion(for: many, preferredSchema: nil)
        XCTAssertTrue(exp.contains("schema:public"))
        XCTAssertFalse(exp.contains("schema:a"))
        XCTAssertTrue(SidebarTree.defaultExpansion(for: many, preferredSchema: "c").contains("schema:c"))
    }
}

// MARK: - Fuzzy index

final class B_SchemaIndexFuzzyTests: XCTestCase {

    private func index() -> SchemaIndex {
        let fn = FunctionNode(schema: "public", name: "refresh_user_stats", kind: .function, arguments: "()", returnType: "void")
        return SchemaIndex(snapshot: snap([
            SchemaNode(name: "public", tables: [
                tbl("public", "users", columns: ["id", "email"]),
                tbl("public", "user_sessions"),
                tbl("public", "orders", columns: ["customer_email"]),
            ], functions: [fn]),
            SchemaNode(name: "sales", tables: [tbl("sales", "users_archive")]),
        ]))
    }

    func testSubsequenceMatchesAndRanksPrefixFirst() {
        let names = index().fuzzy("usr").map(\.entry.name)
        XCTAssertEqual(names.first, "users")
        XCTAssertTrue(names.contains("user_sessions"))
        XCTAssertTrue(names.contains("refresh_user_stats"), "functions are searched too")
        XCTAssertFalse(names.contains("orders"))
    }

    func testSchemaQualifiedQuery() {
        let hits = index().fuzzy("pub.us")
        XCTAssertEqual(hits.first?.entry.name, "users")
        XCTAssertTrue(hits.allSatisfy { $0.entry.schema == "public" })
        XCTAssertEqual(index().fuzzy("sal.us").map(\.entry.name), ["users_archive"])
    }

    func testColumnsOnlyWhenRequested() {
        let idx = index()
        XCTAssertFalse(idx.fuzzy("email").contains { $0.entry.kind == .column })
        let withCols = idx.fuzzy("email", includeColumns: true)
        XCTAssertEqual(Set(withCols.filter { $0.entry.kind == .column }.map(\.entry.name)), ["email", "customer_email"])
    }

    func testIncrementalNarrowingMatchesFreshSearch() {
        let idx = index()
        _ = idx.fuzzy("u")
        _ = idx.fuzzy("us")
        let narrowed = idx.fuzzy("use").map(\.entry.name)
        let fresh = index().fuzzy("use").map(\.entry.name)
        XCTAssertEqual(narrowed, fresh)
        // Backspacing (not an extension) must not reuse the narrower set.
        XCTAssertEqual(idx.fuzzy("o").map(\.entry.name), index().fuzzy("o").map(\.entry.name))
    }

    func testCaseInsensitiveAndEmpty() {
        XCTAssertEqual(index().fuzzy("USERS").first?.entry.name, "users")
        XCTAssertTrue(index().fuzzy("   ").isEmpty)
        XCTAssertTrue(index().fuzzy("zzzq").isEmpty)
    }

    func testByteScorer() {
        let s = { (n: String, h: String) in
            CommandMatcher.fuzzyScore(needle: SchemaIndex.lowered(n), haystack: SchemaIndex.lowered(h))
        }
        XCTAssertNil(s("xyz", "users"))
        XCTAssertGreaterThan(s("us", "users")!, s("us", "bus_stops")!, "prefix beats infix")
        XCTAssertGreaterThan(s("ut", "user_total")!, s("ut", "buttress")! - 1000)
        XCTAssertNotNil(s("usr", "users"))
    }
}

// MARK: - Palette: qualified matching + rank bias

@MainActor
final class B_CommandMatcherQualifiedTests: XCTestCase {

    private func item(_ id: String, _ title: String, schema: String?, bias: Int = 0) -> CommandItem {
        CommandItem(id: id, icon: "tablecells", title: title, subtitle: nil, category: .table,
                    shortcut: nil, action: {}, qualifier: schema, rankBias: bias)
    }

    func testQualifiedQueryMatchesSchemaAndName() {
        let items = [item("a", "users", schema: "public"), item("b", "users", schema: "sales"),
                     item("c", "orders", schema: "public")]
        XCTAssertEqual(CommandMatcher.filter(items, query: "pub.us").map(\.id), ["a"])
        XCTAssertEqual(Set(CommandMatcher.filter(items, query: ".us").map(\.id)), ["a", "b"])
    }

    func testRankBiasOrdersRecentsFirstAndHiddenLast() {
        let items = [item("plain", "users", schema: "public"),
                     item("recent", "users_log", schema: "public", bias: 80),
                     item("hidden", "users", schema: "archive", bias: -60)]
        let ids = CommandMatcher.filter(items, query: "users").map(\.id)
        XCTAssertEqual(ids.first, "recent")
        XCTAssertEqual(ids.last, "hidden")
        XCTAssertEqual(CommandMatcher.filter(items, query: "").map(\.id).first, "recent",
                       "empty query sorts by bias within a category")
    }

    func testGoToItemsIncludeHiddenSchemasRankedLower() {
        let service = ConnectionService(connection: Connection(name: "t", database: "db"))
        let s = snap([SchemaNode(name: "public", tables: [tbl("public", "users"), tbl("public", "v", kind: .view)]),
                      SchemaNode(name: "zz_hidden_test", tables: [tbl("zz_hidden_test", "users")])])
        service.injectSchemaForTests(s)
        let items = CommandProviders.goToItems(service: service)
        XCTAssertEqual(items.first { $0.id == "table.public.v" }?.icon, "rectangle.stack")
        XCTAssertNotNil(items.first { $0.id == "table.zz_hidden_test.users" })
    }
}
