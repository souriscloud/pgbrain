import XCTest
import PostgresNIO
@testable import pgBrain

@MainActor
final class ReplicationFetcherTests: XCTestCase {

    private func isSuperuser(_ db: TestDB) async throws -> Bool {
        try await db.scalarBool("SELECT current_setting('is_superuser') = 'on'")
    }

    func testPublicationsListed() async throws {
        let db = try await TestDB.connectOrSkip(); defer { db.shutdown() }
        // The query always runs; creating a publication needs superuser.
        _ = try await ReplicationFetcher.publications(client: db.client)
        guard try await isSuperuser(db) else {
            throw XCTSkip("CREATE PUBLICATION needs superuser")
        }
        let s = TestDB.uniqueTag(); await db.dropSchemas(s)
        let pub = "pgb_pub_" + UUID().uuidString.prefix(8).lowercased()
        _ = try? await db.client.query(PostgresQuery(unsafeSQL: "DROP PUBLICATION IF EXISTS \(pub)"))
        do {
            try await db.exec("CREATE SCHEMA \"\(s)\"; CREATE TABLE \"\(s)\".t (id int)")
            try await db.exec("CREATE PUBLICATION \(pub) FOR TABLE \"\(s)\".t")
            let pubs = try await ReplicationFetcher.publications(client: db.client)
            let mine = try XCTUnwrap(pubs.first { $0.name == pub })
            XCTAssertFalse(mine.allTables)
            XCTAssertTrue(mine.insert && mine.update && mine.delete && mine.truncate, "default publishes all DML")
            XCTAssertFalse(mine.owner.isEmpty)
            XCTAssertEqual(mine.id, pub)
        } catch {
            _ = try? await db.client.query(PostgresQuery(unsafeSQL: "DROP PUBLICATION IF EXISTS \(pub)"))
            await db.dropSchemas(s); throw error
        }
        _ = try? await db.client.query(PostgresQuery(unsafeSQL: "DROP PUBLICATION IF EXISTS \(pub)"))
        await db.dropSchemas(s)
    }

    func testSubscriptionsQueryRuns() async throws {
        let db = try await TestDB.connectOrSkip(); defer { db.shutdown() }
        // We can't stand up a real logical-replication subscriber here; just
        // exercise the query + decode contract (typically returns []).
        _ = try await ReplicationFetcher.subscriptions(client: db.client)
    }

    func testReplicationSlots() async throws {
        let db = try await TestDB.connectOrSkip(); defer { db.shutdown() }
        _ = try await ReplicationFetcher.slots(client: db.client)
        guard try await isSuperuser(db) else { throw XCTSkip("creating a slot needs superuser") }
        let slot = "pgb_slot_" + UUID().uuidString.prefix(8).lowercased()
        _ = try? await db.client.query(PostgresQuery(unsafeSQL: "SELECT pg_drop_replication_slot('\(slot)')"))
        do {
            // A physical slot works at the default wal_level and exercises the
            // NULL database/plugin decode path.
            _ = try await db.client.query(PostgresQuery(unsafeSQL: "SELECT pg_create_physical_replication_slot('\(slot)')"))
            let slots = try await ReplicationFetcher.slots(client: db.client)
            let mine = try XCTUnwrap(slots.first { $0.name == slot })
            XCTAssertEqual(mine.slotType, "physical")
            XCTAssertNil(mine.plugin, "physical slots have no output plugin")
            XCTAssertEqual(mine.id, slot)
        } catch {
            _ = try? await db.client.query(PostgresQuery(unsafeSQL: "SELECT pg_drop_replication_slot('\(slot)')"))
            throw error
        }
        _ = try? await db.client.query(PostgresQuery(unsafeSQL: "SELECT pg_drop_replication_slot('\(slot)')"))
    }
}

@MainActor
final class ForeignDataFetcherTests: XCTestCase {

    func testForeignServersAndTables() async throws {
        let db = try await TestDB.connectOrSkip(); defer { db.shutdown() }
        // The queries always run.
        _ = try await ForeignDataFetcher.servers(client: db.client)
        _ = try await ForeignDataFetcher.tables(client: db.client)

        guard try await db.scalarBool("SELECT current_setting('is_superuser') = 'on'") else {
            throw XCTSkip("CREATE FOREIGN DATA WRAPPER needs superuser")
        }
        let s = TestDB.uniqueTag(); await db.dropSchemas(s)
        let fdw = "pgb_fdw_" + UUID().uuidString.prefix(8).lowercased()
        let srv = "pgb_srv_" + UUID().uuidString.prefix(8).lowercased()
        func cleanup() async {
            _ = try? await db.client.query(PostgresQuery(unsafeSQL: "DROP SERVER IF EXISTS \(srv) CASCADE"))
            _ = try? await db.client.query(PostgresQuery(unsafeSQL: "DROP FOREIGN DATA WRAPPER IF EXISTS \(fdw) CASCADE"))
            await db.dropSchemas(s)
        }
        await cleanup()
        do {
            try await db.exec("CREATE SCHEMA \"\(s)\"")
            // A handler-less wrapper can't be queried, but the catalog rows we
            // read exist all the same.
            try await db.exec("CREATE FOREIGN DATA WRAPPER \(fdw)")
            try await db.exec("CREATE SERVER \(srv) FOREIGN DATA WRAPPER \(fdw)")
            try await db.exec("CREATE FOREIGN TABLE \"\(s)\".ft (id int) SERVER \(srv)")

            let servers = try await ForeignDataFetcher.servers(client: db.client)
            let mineSrv = try XCTUnwrap(servers.first { $0.name == srv })
            XCTAssertEqual(mineSrv.wrapper, fdw)
            XCTAssertFalse(mineSrv.owner.isEmpty)
            XCTAssertEqual(mineSrv.id, srv)

            let tables = try await ForeignDataFetcher.tables(client: db.client)
            let mineTbl = try XCTUnwrap(tables.first { $0.schema == s && $0.name == "ft" })
            XCTAssertEqual(mineTbl.server, srv)
            XCTAssertEqual(mineTbl.id, "\(s).ft")
        } catch { await cleanup(); throw error }
        await cleanup()
    }
}
