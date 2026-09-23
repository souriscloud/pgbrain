import XCTest
@testable import pgBrain

@MainActor
final class F1_LoaderLifecycleTests: XCTestCase {
    private func table(_ name: String, oid: Int, pk: [String] = ["id"]) -> TableNode {
        var node = TableNode(schema: "public", name: name, kind: .table,
                             columns: [ColumnNode(name: "id", typeName: "integer", nullable: false, ordinal: 1)])
        node.oid = oid
        node.primaryKey = pk
        return node
    }

    private func snapshot(_ tables: [TableNode]) -> SchemaSnapshot {
        SchemaSnapshot(databaseName: "db", schemas: [SchemaNode(name: "public", tables: tables)])
    }

    func testRenameKeepsTabLoaderAndStagedEdits() {
        let service = ConnectionService(connection: Connection(name: "f1-rename"))
        let ws = service.workspace
        ws.openTable(table("old", oid: 7))
        let tab = ws.tabs[0]
        let loader = service.loader(for: tab, table: tab.tableNode!)
        loader.editBuffer.set(row: 0, column: 0, value: "42")
        XCTAssertTrue(tab.hasPendingChanges)

        let result = ws.reconcile(with: snapshot([table("new", oid: 7)]))
        service.syncLoadersWithTabs()

        XCTAssertEqual(result.renamed.map(\.to), ["public.new"])
        XCTAssertEqual(ws.tabs[0].id, tab.id)
        XCTAssertEqual(tab.title, "public.new")
        XCTAssertTrue(service.loader(for: tab, table: tab.tableNode!) === loader, "same loader, not a fresh one")
        XCTAssertTrue(loader.editBuffer.isDirty, "staged edit survived the reload")
        XCTAssertEqual(loader.table.name, "old", "swap waits while edits are staged against the old relation")

        loader.editBuffer.clear()
        XCTAssertEqual(loader.table.name, "new", "adopted once nothing is pending")
    }

    func testPrimaryKeyChangeReachesACleanLoader() {
        let service = ConnectionService(connection: Connection(name: "f1-pk"))
        let ws = service.workspace
        ws.openTable(table("t", oid: 3, pk: ["id"]))
        let tab = ws.tabs[0]
        let loader = service.loader(for: tab, table: tab.tableNode!)
        ws.reconcile(with: snapshot([table("t", oid: 3, pk: ["id", "tenant"])]))
        service.syncLoadersWithTabs()
        XCTAssertEqual(loader.table.primaryKey, ["id", "tenant"])
    }

    func testLoaderGetsItsTabOnCreation() {
        let service = ConnectionService(connection: Connection(name: "f1-tab"))
        service.workspace.openTable(table("t", oid: 1))
        let tab = service.workspace.tabs[0]
        XCTAssertTrue(service.loader(for: tab, table: tab.tableNode!).tab === tab)
    }

    func testShutdownDropsCachedLoaders() {
        let service = ConnectionService(connection: Connection(name: "f1-shutdown"))
        service.workspace.openTable(table("t", oid: 1))
        let tab = service.workspace.tabs[0]
        let before = service.loader(for: tab, table: tab.tableNode!)
        service.shutdown()
        XCTAssertFalse(service.loader(for: tab, table: tab.tableNode!) === before)
    }

    func testLoadLandingKeepsEditsMadeWhileInFlight() {
        XCTAssertFalse(RowsLoader.landingKeepsStagedEdits(revisionAtStart: 3, revisionNow: 3, hasPendingChanges: false))
        XCTAssertFalse(RowsLoader.landingKeepsStagedEdits(revisionAtStart: 3, revisionNow: 3, hasPendingChanges: true),
                       "consented discard: staged before the load started")
        XCTAssertTrue(RowsLoader.landingKeepsStagedEdits(revisionAtStart: 3, revisionNow: 5, hasPendingChanges: true))
        XCTAssertFalse(RowsLoader.landingKeepsStagedEdits(revisionAtStart: 3, revisionNow: 5, hasPendingChanges: false),
                       "edited then undone — nothing to protect")
    }

    func testStagingRevisionBumpsOnEdits() {
        let service = ConnectionService(connection: Connection(name: "f1-rev"))
        let loader = RowsLoader(table: table("t", oid: 1), service: service)
        let start = loader.stagingRevision
        loader.editBuffer.set(row: 0, column: 0, value: "x")
        XCTAssertNotEqual(loader.stagingRevision, start)
    }

    func testHealthNeedsTwoConsecutivePingFailures() {
        XCTAssertFalse(ConnectionService.shouldRecover(afterConsecutivePingFailures: 1))
        XCTAssertTrue(ConnectionService.shouldRecover(afterConsecutivePingFailures: 2))
    }
}
