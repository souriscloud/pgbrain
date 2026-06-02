import XCTest
import PostgresNIO
@testable import pgBrain

/// E2E coverage of the catalog snapshot reader. Builds one scratch schema with
/// every object kind the fetcher understands, then asserts the assembled
/// snapshot reflects it.
final class SchemaFetcherTests: XCTestCase {

    private func node(_ snap: SchemaSnapshot, _ schema: String) -> SchemaNode? {
        snap.schemas.first { $0.name == schema }
    }
    private func table(_ n: SchemaNode?, _ name: String) -> TableNode? {
        n?.tables.first { $0.name == name }
    }

    func testFetchAssemblesEveryObjectKind() async throws {
        let db = try await TestDB.connectOrSkip(); defer { db.shutdown() }
        let s = TestDB.uniqueTag(); await db.dropSchemas(s)
        do {
            try await db.exec("""
            CREATE SCHEMA "\(s)";
            CREATE TYPE "\(s)".mood AS ENUM ('happy', 'sad');
            CREATE TABLE "\(s)".parent (id int PRIMARY KEY, name text NOT NULL, note text);
            CREATE TABLE "\(s)".child  (id int PRIMARY KEY, parent_id int REFERENCES "\(s)".parent(id));
            CREATE VIEW "\(s)".v AS SELECT id FROM "\(s)".parent;
            CREATE MATERIALIZED VIEW "\(s)".mv AS SELECT id FROM "\(s)".parent;
            CREATE FUNCTION "\(s)".f(x integer) RETURNS integer LANGUAGE sql AS 'SELECT x';
            CREATE PROCEDURE "\(s)".p() LANGUAGE sql AS '';
            """)

            let snap = try await SchemaFetcher.fetch(client: db.client)
            let sn = try XCTUnwrap(node(snap, s), "scratch schema should be in the snapshot")

            // Relations + kinds.
            XCTAssertEqual(table(sn, "v")?.kind, .view)
            XCTAssertEqual(table(sn, "mv")?.kind, .materializedView)
            XCTAssertEqual(table(sn, "parent")?.kind, .table)

            // Primary key + (shallow fetch ⇒ no columns yet).
            XCTAssertEqual(table(sn, "parent")?.primaryKey, ["id"])
            XCTAssertTrue(table(sn, "parent")?.columns.isEmpty ?? false, "fetch() is column-shallow")

            // Single-column foreign key on child.
            let fk = try XCTUnwrap(table(sn, "child")?.foreignKeys.first)
            XCTAssertEqual(fk.localColumn, "parent_id")
            XCTAssertEqual(fk.refTable, "parent")
            XCTAssertEqual(fk.refColumn, "id")

            // Functions + procedure kinds.
            XCTAssertEqual(sn.functions.first { $0.name == "f" }?.kind, .function)
            XCTAssertEqual(sn.functions.first { $0.name == "p" }?.kind, .procedure)

            // Enums keyed bare + schema-qualified.
            XCTAssertEqual(snap.enums["mood"], ["happy", "sad"])
            XCTAssertEqual(snap.enums["\(s).mood"], ["happy", "sad"])

            // Database name populated.
            XCTAssertFalse(snap.databaseName.isEmpty)
        } catch { await db.dropSchemas(s); throw error }
        await db.dropSchemas(s)
    }

    func testFetchColumnsAllAndSingleTable() async throws {
        let db = try await TestDB.connectOrSkip(); defer { db.shutdown() }
        let s = TestDB.uniqueTag(); await db.dropSchemas(s)
        do {
            try await db.exec("""
            CREATE SCHEMA "\(s)";
            CREATE TABLE "\(s)".parent (id int PRIMARY KEY, name text NOT NULL, note text);
            """)

            // Bulk column map.
            let map = try await SchemaFetcher.fetchColumnsAll(client: db.client)
            let cols = try XCTUnwrap(map["\(s)\u{1F}parent"])
            XCTAssertEqual(cols.map(\.name), ["id", "name", "note"])

            // Single-table fast path + nullability.
            let single = try await SchemaFetcher.fetchColumns(for: s, table: "parent", client: db.client)
            XCTAssertEqual(single.map(\.name), ["id", "name", "note"])
            XCTAssertFalse(single.first { $0.name == "name" }?.nullable ?? true, "NOT NULL ⇒ not nullable")
            XCTAssertTrue(single.first { $0.name == "note" }?.nullable ?? false, "plain column is nullable")
        } catch { await db.dropSchemas(s); throw error }
        await db.dropSchemas(s)
    }
}
