import XCTest
import PostgresNIO
@testable import pgBrain

/// E2E: the catalog details the navigation overhaul relies on — empty
/// schemas, partitions, foreign/partitioned flavors, extension ownership,
/// oids, alphabetical schema order, and the database list. Skips without a DB.
final class B_SchemaFetcherNavigationTests: XCTestCase {

    func testEmptySchemaPartitionsAndOrdering() async throws {
        let db = try await TestDB.connectOrSkip(); defer { db.shutdown() }
        let s = TestDB.uniqueTag()
        let empty = s + "_empty"
        let fnOnly = s + "_a_fn"
        await db.dropSchemas(s, empty, fnOnly)
        do {
            try await db.exec("""
            CREATE SCHEMA "\(s)";
            CREATE SCHEMA "\(empty)";
            CREATE SCHEMA "\(fnOnly)";
            CREATE FUNCTION "\(fnOnly)".f() RETURNS int LANGUAGE sql AS 'SELECT 1';
            CREATE TABLE "\(s)".events (id int, at date) PARTITION BY RANGE (at);
            CREATE TABLE "\(s)".events_2025 PARTITION OF "\(s)".events FOR VALUES FROM ('2025-01-01') TO ('2026-01-01');
            CREATE TABLE "\(s)".plain (id int)
            """)
            let snap = try await SchemaFetcher.fetch(client: db.client)
            let names = snap.schemas.map(\.name)
            XCTAssertEqual(names, names.sorted(), "schemas are alphabetical, functions-only ones included in order")
            XCTAssertTrue(names.contains(empty), "empty schemas are listed")
            XCTAssertTrue(snap.schemas.first { $0.name == empty }?.isEmpty ?? false)
            XCTAssertEqual(snap.schemas.first { $0.name == fnOnly }?.functions.map(\.name), ["f"])

            let tables = try XCTUnwrap(snap.schemas.first { $0.name == s }?.tables)
            let parent = try XCTUnwrap(tables.first { $0.name == "events" })
            let part = try XCTUnwrap(tables.first { $0.name == "events_2025" })
            XCTAssertEqual(parent.flavor, .partitioned)
            XCTAssertEqual(part.partitionOf, "\(s).events")
            XCTAssertNil(tables.first { $0.name == "plain" }?.partitionOf)
            XCTAssertNotEqual(parent.oid, 0)
            XCTAssertFalse(parent.isExtensionOwned)
        } catch { await db.dropSchemas(s, empty, fnOnly); throw error }
        await db.dropSchemas(s, empty, fnOnly)
    }

    func testExtensionOwnedObjectsAreFlagged() async throws {
        let db = try await TestDB.connectOrSkip(); defer { db.shutdown() }
        let available = try await db.scalarBool("""
            SELECT EXISTS (SELECT 1 FROM pg_available_extensions WHERE name = 'seg' AND installed_version IS NULL)
            """)
        guard available else { throw XCTSkip("contrib 'seg' not available (or already installed) on the test server") }
        let s = TestDB.uniqueTag()
        await db.dropSchemas(s)
        do {
            try await db.exec("""
            CREATE SCHEMA "\(s)";
            CREATE EXTENSION seg SCHEMA "\(s)";
            CREATE FUNCTION "\(s)".mine() RETURNS int LANGUAGE sql AS 'SELECT 1'
            """)
            let snap = try await SchemaFetcher.fetch(client: db.client)
            let fns = try XCTUnwrap(snap.schemas.first { $0.name == s }?.functions)
            XCTAssertEqual(fns.first { $0.name == "mine" }?.isExtensionOwned, false)
            XCTAssertTrue(fns.contains { $0.name.hasPrefix("seg_") && $0.isExtensionOwned },
                          "functions created by CREATE EXTENSION are extension-owned")
        } catch {
            _ = try? await db.exec("DROP EXTENSION IF EXISTS seg")
            await db.dropSchemas(s)
            throw error
        }
        _ = try? await db.exec("DROP EXTENSION IF EXISTS seg")
        await db.dropSchemas(s)
    }

    func testDatabaseListExcludesTemplates() async throws {
        let db = try await TestDB.connectOrSkip(); defer { db.shutdown() }
        let list = try await DatabaseCatalog.fetchDatabases(client: db.client)
        let current = try await db.scalarString("SELECT current_database()")
        XCTAssertTrue(list.contains(current))
        XCTAssertFalse(list.contains("template0"))
        XCTAssertFalse(list.contains("template1"))
        XCTAssertEqual(list, list.sorted())
    }
}
