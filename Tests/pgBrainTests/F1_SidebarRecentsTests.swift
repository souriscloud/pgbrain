import XCTest
@testable import pgBrain

@MainActor
final class F1_SidebarRecentsTests: XCTestCase {
    private func t(_ name: String) -> TableNode {
        TableNode(schema: "public", name: name, kind: .table, columns: [])
    }

    func testPreviewDoesNotRecordButPromotionDoes() {
        let ws = WorkspaceState()
        var opened: [String] = []
        ws.onTableOpened = { opened.append($0.id) }

        ws.openTable(t("a"), preview: true)
        ws.openTable(t("b"), preview: true)
        XCTAssertEqual(opened, [], "single-click previews must not reshuffle Recent")

        ws.keepTab(id: ws.tabs[0].id)
        XCTAssertEqual(opened, ["public.b"], "keeping the preview counts as opening it")

        ws.openTable(t("c"))
        XCTAssertEqual(opened.last, "public.c")
    }

    func testEditingAPreviewRecordsIt() {
        let ws = WorkspaceState()
        var opened: [String] = []
        ws.onTableOpened = { opened.append($0.id) }
        ws.openTable(t("a"), preview: true)
        ws.tabs[0].hasPendingChanges = true
        XCTAssertEqual(opened, ["public.a"])
    }

    func testRecentsChangeSwapsOnlySections() {
        let snap = SchemaSnapshot(databaseName: "db", schemas: [SchemaNode(name: "public", tables: [t("a"), t("b")])])
        let before = SidebarContent(snapshot: snap, recents: ["public.a"])
        var after = before
        after.recents = ["public.b", "public.a"]
        XCTAssertTrue(SidebarTree.onlySectionsChanged(from: before, to: after))
        XCTAssertFalse(SidebarTree.onlySectionsChanged(from: before, to: before), "no change at all")
        XCTAssertFalse(SidebarTree.onlySectionsChanged(from: nil, to: after), "first build")

        var reloaded = after
        reloaded.snapshot = SchemaSnapshot(databaseName: "db", schemas: [SchemaNode(name: "public", tables: [t("a")])])
        XCTAssertFalse(SidebarTree.onlySectionsChanged(from: before, to: reloaded), "schema change needs a full rebuild")
    }

    func testSectionsBuildMatchesFullBuild() {
        let snap = SchemaSnapshot(databaseName: "db", schemas: [SchemaNode(name: "public", tables: [t("a"), t("b")])])
        let content = SidebarContent(snapshot: snap, pinned: ["public.b"], recents: ["public.a", "public.b", "public.gone"])
        let sections = SidebarTree.sections(content)
        let full = SidebarTree.build(content).roots.filter(\.isSection)
        XCTAssertEqual(sections.map(\.id), full.map(\.id))
        XCTAssertEqual(sections.map { $0.children.map(\.id) }, full.map { $0.children.map(\.id) })
        XCTAssertEqual(sections.last?.children.map(\.id), ["recent/table:public.a"], "pinned and vanished tables are skipped")
    }
}
