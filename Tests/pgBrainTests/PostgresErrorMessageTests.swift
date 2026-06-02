import XCTest
import PostgresNIO
@testable import pgBrain

/// Coverage of the PostgresNIO-error humaniser. The generic fallback is pure;
/// the PSQLError / transaction paths need real server errors, so they're driven
/// against a live database.
final class PostgresErrorMessageTests: XCTestCase {

    private struct Boom: LocalizedError { var errorDescription: String? { "boom" } }

    func testGenericErrorFallsBackToLocalizedDescription() {
        XCTAssertEqual(PostgresErrorMessage.describe(Boom()), "boom")
    }

    func testServerErrorSurfacesMessageAndSqlState() async throws {
        let db = try await TestDB.connectOrSkip(); defer { db.shutdown() }
        do {
            _ = try await db.client.query("SELECT * FROM definitely_not_a_real_table_xyz")
            XCTFail("expected a server error")
        } catch {
            let described = PostgresErrorMessage.describe(error)
            // PG says: relation "…" does not exist  [42P01]
            XCTAssertTrue(described.lowercased().contains("does not exist"), described)
            XCTAssertTrue(described.contains("[42P01]"), "SQLSTATE is attached: \(described)")
        }
    }

    func testTransactionErrorIsLabelledRolledBack() async throws {
        let db = try await TestDB.connectOrSkip(); defer { db.shutdown() }
        do {
            // Any error thrown from the closure is wrapped as a
            // PostgresTransactionError(closureError:), which is the branch under
            // test; describe() recurses into it and appends our message.
            try await db.client.withTransaction(logger: pgbrainQuietLogger) { _ in
                throw Boom()
            }
            XCTFail("expected a transaction error")
        } catch {
            let described = PostgresErrorMessage.describe(error)
            XCTAssertTrue(described.contains("rolled back"), described)
            XCTAssertTrue(described.contains("boom"), described)
        }
    }
}
