import Foundation
import XCTest
@testable import pgBrain

/// A session that dies between statements must not carry the next statement
/// onto a fresh connection while the user thinks a transaction is open.
final class F2_ScratchpadSessionLossTests: XCTestCase {

    func testIdleLossDecision() {
        XCTAssertEqual(ScratchpadSession.idleLossAction(lastStatus: .idle), .carryOver)
        XCTAssertEqual(ScratchpadSession.idleLossAction(lastStatus: .active), .failTransactionLost)
        XCTAssertEqual(ScratchpadSession.idleLossAction(lastStatus: .failed), .failTransactionLost)
    }

    @MainActor
    func testEndpointMovedComparesHostAndPort() {
        let current = PGWireEndpoint(host: "127.0.0.1", port: 50_001, tlsServerName: nil,
                                     username: "u", password: nil, database: nil, sslMode: .disable)
        XCTAssertFalse(NotebookRunner.endpointMoved(current, to: .init(host: "127.0.0.1", port: 50_001)))
        XCTAssertTrue(NotebookRunner.endpointMoved(current, to: .init(host: "127.0.0.1", port: 50_002)))
        XCTAssertTrue(NotebookRunner.endpointMoved(current, to: .init(host: "::1", port: 50_001)))
    }

    func testStatementAfterLostTransactionIsNotSent() async throws {
        let endpoint = try await E_ScratchpadSessionTests.endpointOrSkip()
        let db = try await TestDB.connectOrSkip()
        defer { db.shutdown() }
        let table = TestDB.uniqueTag()
        try await db.exec("CREATE TABLE public.\(table) (v int)")

        let session = ScratchpadSession(endpoint: endpoint)
        let killer = ScratchpadSession(endpoint: endpoint)
        defer { session.close(); killer.close() }
        _ = try await session.run("BEGIN", rowLimit: 1)
        XCTAssertEqual(session.transactionStatus, .active)
        let pid = try XCTUnwrap(session.backendPID)
        _ = try await killer.run("SELECT pg_terminate_backend(\(pid))", rowLimit: 1)
        try await Task.sleep(nanoseconds: 300_000_000)

        do {
            _ = try await session.run("INSERT INTO public.\(table) VALUES (1)", rowLimit: 1)
            XCTFail("expected transactionLost")
        } catch let error as PGWireError {
            XCTAssertEqual(error, .transactionLost)
        }
        XCTAssertEqual(session.transactionStatus, .idle)
        let count = try await db.scalarInt("SELECT count(*)::int FROM public.\(table)")
        XCTAssertEqual(count, 0, "the statement must not autocommit on a fresh session")

        let r = try await session.run("SELECT 'back'", rowLimit: 1)
        XCTAssertEqual(r.result.page.rows.first?.first, "back")
        XCTAssertTrue(r.reconnected)
        try await db.exec("DROP TABLE IF EXISTS public.\(table)")
    }
}
