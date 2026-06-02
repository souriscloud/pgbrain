import XCTest
@testable import pgBrain

// Helpers shared across the store tests.
@MainActor
private enum TestPaths {
    static func tempURL() -> URL {
        FileManager.default.temporaryDirectory.appendingPathComponent("pgbrain-test-\(UUID().uuidString).json")
    }
    static func suite() -> UserDefaults {
        UserDefaults(suiteName: "pgbrain.tests.\(UUID().uuidString)")!
    }
}

// MARK: - SessionState (pure Codable, no seam)

final class SessionStateTests: XCTestCase {
    func testCodableRectRoundTrip() {
        let r = SessionState.CodableRect(NSRect(x: 1, y: 2, width: 3, height: 4))
        XCTAssertEqual(r.x, 1); XCTAssertEqual(r.y, 2); XCTAssertEqual(r.w, 3); XCTAssertEqual(r.h, 4)
        XCTAssertEqual(r.ns, NSRect(x: 1, y: 2, width: 3, height: 4))
    }

    func testSessionStateEncodeDecode() throws {
        var state = SessionState()
        XCTAssertEqual(state.version, 1)
        let tableTab = SessionState.Tab(kind: .table, tableSchema: "public", tableName: "users",
                                        tableWhereClause: "id > 1", tableOrderByClause: nil,
                                        scratchpadTitle: nil, scratchpadText: nil, scratchpadSearchPath: nil,
                                        colorTag: "red", tabTitle: nil)
        let padTab = SessionState.Tab(kind: .scratchpad, tableSchema: nil, tableName: nil,
                                      tableWhereClause: nil, tableOrderByClause: nil,
                                      scratchpadTitle: "Q1", scratchpadText: "SELECT 1",
                                      scratchpadSearchPath: "public", colorTag: nil, tabTitle: "renamed")
        state.windows = [SessionState.Window(connectionID: UUID(),
                                             frame: SessionState.CodableRect(NSRect(x: 10, y: 20, width: 800, height: 600)),
                                             tabs: [tableTab, padTab], selectedTabIndex: 1)]
        let data = try JSONEncoder().encode(state)
        let back = try JSONDecoder().decode(SessionState.self, from: data)
        XCTAssertEqual(back.windows.count, 1)
        XCTAssertEqual(back.windows[0].tabs.count, 2)
        XCTAssertEqual(back.windows[0].tabs[0].tableName, "users")
        XCTAssertEqual(back.windows[0].tabs[1].scratchpadText, "SELECT 1")
        XCTAssertEqual(back.windows[0].selectedTabIndex, 1)
        XCTAssertEqual(back.windows[0].frame.ns.width, 800)
    }

    func testOlderSnapshotMissingOptionalFieldsDecodes() throws {
        // A pre-color-tag tab JSON (only kind) must still decode.
        let json = #"{"version":1,"savedAt":0,"windows":[{"connectionID":"\#(UUID().uuidString)","frame":{"x":0,"y":0,"w":100,"h":100},"tabs":[{"kind":"scratchpad"}],"selectedTabIndex":null}]}"#
        let back = try JSONDecoder().decode(SessionState.self, from: Data(json.utf8))
        XCTAssertEqual(back.windows[0].tabs[0].kind, .scratchpad)
        XCTAssertNil(back.windows[0].tabs[0].colorTag)
    }
}

// MARK: - SnippetStore

@MainActor
final class SnippetStoreTests: XCTestCase {
    func testExpandPlaceholders() {
        XCTAssertEqual(SnippetStore.expand("SELECT $cursor$ FROM t").text, "SELECT  FROM t")
        XCTAssertEqual(SnippetStore.expand("SELECT $cursor$ FROM t").caret, 7)
        XCTAssertEqual(SnippetStore.expand("a $1$ b").text, "a  b")
        // $cursor$ wins over $1$.
        XCTAssertEqual(SnippetStore.expand("$cursor$x$1$").caret, 0)
        // No placeholder → caret at end.
        let plain = SnippetStore.expand("done")
        XCTAssertEqual(plain.text, "done")
        XCTAssertEqual(plain.caret, 4)
    }

    func testAddSortsAndRejectsEmpty() {
        let store = SnippetStore(testURL: TestPaths.tempURL())
        store.add(name: "  Zed  ", body: "z")
        store.add(name: "alpha", body: "a")
        store.add(name: "", body: "x")          // rejected (empty name)
        store.add(name: "ok", body: "")          // rejected (empty body)
        XCTAssertEqual(store.snippets.map(\.name), ["alpha", "Zed"], "trimmed + case-insensitive sorted")
    }

    func testUpdateAndDelete() {
        let store = SnippetStore(testURL: TestPaths.tempURL())
        store.add(name: "b", body: "1")
        store.add(name: "a", body: "2")
        let target = store.snippets.first { $0.name == "b" }!
        store.update(id: target.id, name: "aa", body: "new")
        XCTAssertEqual(store.snippets.map(\.name), ["a", "aa"], "re-sorted after rename")
        XCTAssertEqual(store.snippets.first { $0.id == target.id }?.body, "new")
        store.update(id: UUID(), name: "ghost")  // no-op
        store.delete(id: target.id)
        XCTAssertEqual(store.snippets.map(\.name), ["a"])
    }

    func testPersistRoundTrip() {
        let url = TestPaths.tempURL(); defer { try? FileManager.default.removeItem(at: url) }
        let a = SnippetStore(testURL: url)
        a.add(name: "keep", body: "SELECT 1")
        a.flushNowForTests()
        let b = SnippetStore(testURL: url)
        XCTAssertEqual(b.snippets.map(\.name), ["keep"])
    }
}

// MARK: - SavedQueryStore

@MainActor
final class SavedQueryStoreTests: XCTestCase {
    func testUpsertInsertsNewestFirstAndUpdatesInPlace() {
        let store = SavedQueryStore(testURL: TestPaths.tempURL())
        let first = SavedQuery(name: "first", sql: "SELECT 1")
        let second = SavedQuery(name: "second", sql: "SELECT 2")
        store.upsert(first)
        store.upsert(second)
        XCTAssertEqual(store.queries.map(\.name), ["second", "first"], "newest inserted at front")

        var edited = first; edited.name = "first-edited"
        store.upsert(edited)
        XCTAssertEqual(store.queries.count, 2, "same id updates in place")
        XCTAssertEqual(store.queries.first { $0.id == first.id }?.name, "first-edited")
    }

    func testRemoveAndMatching() {
        let store = SavedQueryStore(testURL: TestPaths.tempURL())
        let a = SavedQuery(name: "users report", notes: "monthly", sql: "SELECT * FROM users")
        let b = SavedQuery(name: "orders", notes: "", sql: "SELECT * FROM orders")
        store.upsert(a)
        store.upsert(b)
        // Empty term returns everything.
        XCTAssertEqual(store.matching("").count, 2)
        // Matches name, notes, or SQL body (case-insensitive substring).
        XCTAssertEqual(store.matching("USERS").map(\.name), ["users report"])
        XCTAssertEqual(store.matching("monthly").map(\.name), ["users report"])
        XCTAssertEqual(store.matching("orders").map(\.name), ["orders"])
        XCTAssertTrue(store.matching("nonexistent").isEmpty)

        store.remove(id: a.id)
        XCTAssertEqual(store.queries.map(\.name), ["orders"])
    }

    func testPersistRoundTrip() {
        let url = TestPaths.tempURL(); defer { try? FileManager.default.removeItem(at: url) }
        let a = SavedQueryStore(testURL: url)
        a.upsert(SavedQuery(name: "kept", sql: "SELECT 42"))
        a.flushNowForTests()
        let b = SavedQueryStore(testURL: url)
        XCTAssertEqual(b.queries.map(\.name), ["kept"])
    }
}

// MARK: - QueryHistoryStore

@MainActor
final class QueryHistoryStoreTests: XCTestCase {
    func testRecordFilterAndClear() {
        let store = QueryHistoryStore(testURL: TestPaths.tempURL())
        let c1 = UUID(); let c2 = UUID()
        store.record(connectionID: c1, sql: " SELECT 1 ", startedAt: Date(), elapsedSec: 0.1, success: true, errorMessage: nil, rowsAffected: 1)
        store.record(connectionID: c1, sql: "SELECT 2", startedAt: Date(), elapsedSec: 0.2, success: false, errorMessage: "boom", rowsAffected: nil)
        store.record(connectionID: c2, sql: "SELECT 3", startedAt: Date(), elapsedSec: 0.1, success: true, errorMessage: nil, rowsAffected: 0)
        store.record(connectionID: c1, sql: "   ", startedAt: Date(), elapsedSec: 0, success: true, errorMessage: nil, rowsAffected: nil) // rejected

        let forC1 = store.entries(for: c1)
        XCTAssertEqual(forC1.count, 2)
        XCTAssertEqual(forC1.first?.sql, "SELECT 2", "most recent first (reversed)")
        XCTAssertEqual(forC1.last?.sql, "SELECT 1", "whitespace trimmed")

        store.clear(for: c1)
        XCTAssertTrue(store.entries(for: c1).isEmpty)
        XCTAssertEqual(store.entries(for: c2).count, 1, "other connection untouched")
    }

    func testFifoCapAt5000() {
        let store = QueryHistoryStore(testURL: TestPaths.tempURL())
        let c = UUID()
        for i in 0..<5001 {
            store.record(connectionID: c, sql: "q\(i)", startedAt: Date(), elapsedSec: 0, success: true, errorMessage: nil, rowsAffected: nil)
        }
        XCTAssertEqual(store.entries.count, 5000, "capped")
        XCTAssertEqual(store.entries.first?.sql, "q1", "oldest (q0) evicted FIFO")
    }

    func testPersistRoundTrip() {
        let url = TestPaths.tempURL(); defer { try? FileManager.default.removeItem(at: url) }
        let a = QueryHistoryStore(testURL: url)
        a.record(connectionID: UUID(), sql: "SELECT 9", startedAt: Date(), elapsedSec: 0, success: true, errorMessage: nil, rowsAffected: nil)
        a.flushNowForTests()
        let b = QueryHistoryStore(testURL: url)
        XCTAssertEqual(b.entries.map(\.sql), ["SELECT 9"])
    }
}

// MARK: - ColumnLayoutStore

@MainActor
final class ColumnLayoutStoreTests: XCTestCase {
    func testSetAndGetWidthKeyedByConnectionSchemaTable() {
        let store = ColumnLayoutStore(testURL: TestPaths.tempURL())
        let c = UUID()
        store.setWidth(120, connectionID: c, schema: "public", table: "t", column: "id")
        store.setWidth(80, connectionID: c, schema: "public", table: "t", column: "name")
        XCTAssertEqual(store.width(connectionID: c, schema: "public", table: "t", column: "id"), 120)
        XCTAssertEqual(store.width(connectionID: c, schema: "public", table: "t", column: "name"), 80)
        XCTAssertNil(store.width(connectionID: c, schema: "public", table: "other", column: "id"))
        XCTAssertNil(store.width(connectionID: UUID(), schema: "public", table: "t", column: "id"))
    }

    func testPersistRoundTrip() {
        let url = TestPaths.tempURL(); defer { try? FileManager.default.removeItem(at: url) }
        let c = UUID()
        let a = ColumnLayoutStore(testURL: url)
        a.setWidth(99, connectionID: c, schema: "s", table: "t", column: "col")
        a.flushNowForTests()
        let b = ColumnLayoutStore(testURL: url)
        XCTAssertEqual(b.width(connectionID: c, schema: "s", table: "t", column: "col"), 99)
    }
}

// MARK: - WorkspaceStore

@MainActor
final class WorkspaceStoreTests: XCTestCase {
    private func ws(_ name: String) -> SavedWorkspace {
        SavedWorkspace(id: UUID(), name: name, tabs: [], selectedTabIndex: nil, createdAt: Date())
    }

    func testSaveUpdateDeleteRenameSorted() {
        let store = WorkspaceStore(testURL: TestPaths.tempURL())
        let c = UUID()
        let zed = ws("zed"); let alpha = ws("alpha")
        store.save(zed, for: c)
        store.save(alpha, for: c)
        XCTAssertEqual(store.workspaces(for: c).map(\.name), ["alpha", "zed"], "sorted")

        var updated = zed; updated.name = "zed2"
        store.save(updated, for: c)   // same id → update
        XCTAssertEqual(store.workspaces(for: c).count, 2)
        XCTAssertTrue(store.workspaces(for: c).contains { $0.name == "zed2" })

        store.rename(id: alpha.id, to: "aaa", for: c)
        XCTAssertEqual(store.workspaces(for: c).first?.name, "aaa")
        store.rename(id: UUID(), to: "x", for: c)  // no-op

        store.delete(id: alpha.id, for: c)
        store.delete(id: updated.id, for: c)
        XCTAssertTrue(store.workspaces(for: c).isEmpty, "empty connection pruned")
    }

    func testPersistRoundTrip() {
        let url = TestPaths.tempURL(); defer { try? FileManager.default.removeItem(at: url) }
        let c = UUID()
        let a = WorkspaceStore(testURL: url)
        a.save(ws("saved"), for: c)
        a.flushNowForTests()
        let b = WorkspaceStore(testURL: url)
        XCTAssertEqual(b.workspaces(for: c).map(\.name), ["saved"])
    }
}

// MARK: - ConnectionStore (synchronous save)

@MainActor
final class ConnectionStoreTests: XCTestCase {
    func testUpsertRemoveAndLookup() {
        let url = TestPaths.tempURL(); defer { try? FileManager.default.removeItem(at: url) }
        let store = ConnectionStore(testURL: url)
        var c = Connection(name: "DB", host: "h", port: 5432, database: "d", username: "u")
        store.upsert(c)
        XCTAssertEqual(store.connections.count, 1)
        XCTAssertEqual(store.connection(id: c.id)?.name, "DB")
        c.name = "DB2"
        store.upsert(c)   // same id → in place
        XCTAssertEqual(store.connections.count, 1)
        XCTAssertEqual(store.connection(id: c.id)?.name, "DB2")
        store.remove(c)
        XCTAssertTrue(store.connections.isEmpty)
    }

    func testImportConnectionsDedupes() {
        let store = ConnectionStore(testURL: TestPaths.tempURL())
        let base = Connection(name: "Prod", host: "h", port: 5432, database: "app", username: "u")
        let dup = Connection(name: "Prod", host: "h", port: 5432, database: "app", username: "u") // different id, same fields
        let distinct = Connection(name: "Other", host: "h2", port: 5432, database: "app", username: "u")
        let added = store.importConnections([
            .init(connection: base, password: nil),
            .init(connection: dup, password: nil),
            .init(connection: distinct, password: nil),
        ])
        XCTAssertEqual(added, 2, "exact-field duplicate skipped")
        XCTAssertEqual(store.connections.count, 2)
    }

    func testPersistRoundTrip() {
        let url = TestPaths.tempURL(); defer { try? FileManager.default.removeItem(at: url) }
        let a = ConnectionStore(testURL: url)
        a.upsert(Connection(name: "Persisted", host: "h", port: 5432, database: "d", username: "u"))
        let b = ConnectionStore(testURL: url)   // save() is synchronous
        XCTAssertEqual(b.connections.map(\.name), ["Persisted"])
    }
}

// MARK: - SchemaVisibility (UserDefaults)

@MainActor
final class SchemaVisibilityTests: XCTestCase {
    func testHideShowToggleClearAndPrune() {
        let suiteName = "pgbrain.tests.\(UUID().uuidString)"
        let suite = UserDefaults(suiteName: suiteName)!
        defer { suite.removePersistentDomain(forName: suiteName) }
        let store = SchemaVisibility(testDefaults: suite)
        let c = UUID()
        XCTAssertTrue(store.hidden(for: c).isEmpty)

        store.setHidden(true, schema: "pg_catalog", connectionID: c)
        XCTAssertTrue(store.isHidden("pg_catalog", connectionID: c))
        store.toggle(schema: "tmp", connectionID: c)
        XCTAssertEqual(store.hidden(for: c), ["pg_catalog", "tmp"])

        store.toggle(schema: "pg_catalog", connectionID: c)   // un-hide
        XCTAssertFalse(store.isHidden("pg_catalog", connectionID: c))

        store.clear(connectionID: c)
        XCTAssertTrue(store.hidden(for: c).isEmpty, "cleared")

        // Removing the last hidden schema prunes the connection key entirely.
        store.setHidden(true, schema: "only", connectionID: c)
        store.setHidden(false, schema: "only", connectionID: c)
        XCTAssertTrue(store.hidden(for: c).isEmpty)
    }

    func testPersistRoundTripViaSuite() {
        let suiteName = "pgbrain.tests.\(UUID().uuidString)"
        let suite = UserDefaults(suiteName: suiteName)!
        defer { suite.removePersistentDomain(forName: suiteName) }
        let c = UUID()
        let a = SchemaVisibility(testDefaults: suite)
        a.setHidden(true, schema: "secret", connectionID: c)
        let b = SchemaVisibility(testDefaults: suite)
        XCTAssertTrue(b.isHidden("secret", connectionID: c))
    }
}

// MARK: - AppSettings (UserDefaults)

@MainActor
final class AppSettingsTests: XCTestCase {
    func testFirstLaunchDefaults() {
        let s = AppSettings(testDefaults: TestPaths.suite())
        XCTAssertTrue(s.restoreLastSession)
        XCTAssertEqual(s.defaultRowLimit, 1000)
        XCTAssertEqual(s.editorFontSize, 12)
        XCTAssertEqual(s.sparkleChannel, "stable")
        XCTAssertEqual(s.pgDumpPath, "")
        XCTAssertFalse(s.verbosePostgresLogging)
    }

    func testEditorFontSizeClampsAndBumps() {
        let s = AppSettings(testDefaults: TestPaths.suite())
        XCTAssertEqual(AppSettings.fontRange, 9...28)
        s.editorFontSize = 100
        XCTAssertEqual(s.editorFontSize, 28, "clamped to max")
        s.editorFontSize = 1
        XCTAssertEqual(s.editorFontSize, 9, "clamped to min")
        s.editorFontSize = 14
        s.bumpFontSize(by: 100)
        XCTAssertEqual(s.editorFontSize, 28)
        s.bumpFontSize(by: -100)
        XCTAssertEqual(s.editorFontSize, 9)
    }

    func testValuesPersistToSuite() {
        let suite = TestPaths.suite()
        let a = AppSettings(testDefaults: suite)
        a.defaultRowLimit = 250
        a.sparkleChannel = "beta"
        a.pgDumpPath = "/usr/bin/pg_dump"
        let b = AppSettings(testDefaults: suite)
        XCTAssertEqual(b.defaultRowLimit, 250)
        XCTAssertEqual(b.sparkleChannel, "beta")
        XCTAssertEqual(b.pgDumpPath, "/usr/bin/pg_dump")
    }
}
