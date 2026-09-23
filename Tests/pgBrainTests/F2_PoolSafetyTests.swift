import Foundation
import NIOSSL
import PostgresNIO
import XCTest
@testable import pgBrain

/// E2E on a one-connection pool, so every call provably reuses the same
/// backend: imports can't be captured by a same-named temp table, and no
/// path hands the connection back with a transaction open.
final class F2_PoolSafetyTests: XCTestCase {

    private struct SingleClient {
        let client: PostgresClient
        let task: Task<Void, Never>
        func shutdown() { task.cancel() }
    }

    private func singleConnectionClient() async throws -> SingleClient {
        let endpoint = try await E_ScratchpadSessionTests.endpointOrSkip()
        let tls: PostgresClient.Configuration.TLS
        if endpoint.sslMode == .disable {
            tls = .disable
        } else {
            var cfg = TLSConfiguration.makeClientConfiguration()
            cfg.certificateVerification = .none
            tls = .prefer(cfg)
        }
        var config = PostgresClient.Configuration(
            host: endpoint.host, port: endpoint.port,
            username: endpoint.username, password: endpoint.password,
            database: endpoint.database, tls: tls)
        config.options.maximumConnections = 1
        config.options.minimumConnections = 0
        let client = PostgresClient(configuration: config)
        let task = Task { await client.run() }
        return SingleClient(client: client, task: task)
    }

    private func scalar(_ client: PostgresClient, _ sql: String) async throws -> String? {
        let r = try await QueryRunner.run(sql, on: client)
        return r.page.rows.first?.first ?? nil
    }

    /// SAVEPOINT only succeeds inside a transaction block (open or aborted
    /// fails differently, but either way it isn't 25P01 "no transaction").
    private func inTransactionBlock(_ client: PostgresClient) async throws -> Bool {
        try await client.withConnection { conn in
            do {
                _ = try await conn.query(PostgresQuery(unsafeSQL: "SAVEPOINT pgb_probe"), logger: pgbrainQuietLogger)
            } catch let error as PSQLError where error.serverInfo?[.sqlState] == "25P01" {
                return false
            } catch {
                _ = try? await conn.query(PostgresQuery(unsafeSQL: "ROLLBACK"), logger: pgbrainQuietLogger)
                return true
            }
            _ = try? await conn.query(PostgresQuery(unsafeSQL: "ROLLBACK"), logger: pgbrainQuietLogger)
            return true
        }
    }

    func testDetectorBaseline() async throws {
        let single = try await singleConnectionClient(); defer { single.shutdown() }
        let fresh = try await inTransactionBlock(single.client)
        XCTAssertFalse(fresh, "detector baseline")
    }

    func testSearchPathPutsTempLast() {
        XCTAssertEqual(Importer.copySearchPath(schema: "s"), #"SET LOCAL search_path = "s", pg_catalog, pg_temp"#)
    }

    func testOpensTransaction() {
        XCTAssertTrue(PooledTransaction.opensTransaction("BEGIN"))
        XCTAssertTrue(PooledTransaction.opensTransaction("  begin isolation level serializable"))
        XCTAssertTrue(PooledTransaction.opensTransaction("START TRANSACTION"))
        XCTAssertFalse(PooledTransaction.opensTransaction("SELECT 'begin'"))
        XCTAssertFalse(PooledTransaction.opensTransaction("COMMIT"))
    }

    func testImportIgnoresSameNamedTempTable() async throws {
        let db = try await TestDB.connectOrSkip(); defer { db.shutdown() }
        let single = try await singleConnectionClient(); defer { single.shutdown() }
        let s = TestDB.uniqueTag(); await db.dropSchemas(s)
        let csv = FileManager.default.temporaryDirectory.appendingPathComponent("pgb-f2-\(UUID().uuidString).csv")
        defer { try? FileManager.default.removeItem(at: csv) }
        do {
            try await db.exec("CREATE SCHEMA \"\(s)\"; CREATE TABLE \"\(s)\".t (v text)")
            _ = try await QueryRunner.run("CREATE TEMP TABLE t (v text)", on: single.client)
            try Data("v\nhello\n".utf8).write(to: csv)
            let table = TableNode(schema: s, name: "t", kind: .table, columns: [
                ColumnNode(name: "v", typeName: "text", nullable: true, ordinal: 0),
            ], primaryKey: [])
            let stats = try await Importer.importCSV(into: table, from: csv, client: single.client)
            XCTAssertEqual(stats.rowsImported, 1)
            let real = try await scalar(single.client, "SELECT count(*)::text FROM \"\(s)\".t")
            let temp = try await scalar(single.client, "SELECT count(*)::text FROM pg_temp.t")
            XCTAssertEqual(real, "1", "the chosen table got the row")
            XCTAssertEqual(temp, "0", "the temp table was not written")
        } catch { await db.dropSchemas(s); throw error }
        await db.dropSchemas(s)
    }

    func testPooledBeginDoesNotLeakIntoNextCaller() async throws {
        let single = try await singleConnectionClient(); defer { single.shutdown() }
        _ = try await QueryRunner.run("BEGIN", on: single.client)
        let open = try await inTransactionBlock(single.client)
        XCTAssertFalse(open)
    }

    func testFailedPooledTransactionReturnsCleanConnection() async throws {
        let single = try await singleConnectionClient(); defer { single.shutdown() }
        struct Boom: Error {}
        do {
            try await PooledTransaction.run(client: single.client) { conn in
                _ = try await conn.query(PostgresQuery(unsafeSQL: "SELECT 1/0"), logger: pgbrainQuietLogger)
            }
            XCTFail("expected division by zero")
        } catch {}
        let open = try await inTransactionBlock(single.client)
        XCTAssertFalse(open, "aborted transaction was rolled back before release")
        do {
            let _: Int = try await PooledTransaction.run(client: single.client) { _ in throw Boom() }
            XCTFail("expected Boom")
        } catch is Boom {}
        let stillOpen = try await inTransactionBlock(single.client)
        XCTAssertFalse(stillOpen)
    }
}
