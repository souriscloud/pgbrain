import XCTest
import PostgresNIO
@testable import pgBrain

@MainActor
final class SequenceFetcherTests: XCTestCase {

    func testFetchAllReportsOwnershipAndLastValue() async throws {
        let db = try await TestDB.connectOrSkip(); defer { db.shutdown() }
        let s = TestDB.uniqueTag(); await db.dropSchemas(s)
        do {
            try await db.exec("""
            CREATE SCHEMA "\(s)";
            CREATE SEQUENCE "\(s)".standalone;
            CREATE TABLE "\(s)".t (id int GENERATED ALWAYS AS IDENTITY);
            """)

            let all = try await SequenceFetcher.fetchAll(client: db.client)
            let mine = all.filter { $0.schema == s }
            XCTAssertEqual(mine.count, 2, "standalone + identity-owned sequences")

            let standalone = try XCTUnwrap(mine.first { $0.name == "standalone" })
            XCTAssertEqual(standalone.ownedBy, "", "a plain sequence has no owner column")
            XCTAssertNil(standalone.lastValue, "never read ⇒ NULL last_value")
            XCTAssertEqual(standalone.id, "\(s).standalone")
            XCTAssertEqual(standalone.increment, 1)

            let identity = try XCTUnwrap(mine.first { $0.name != "standalone" })
            XCTAssertEqual(identity.ownedBy, "\(s).t.id", "identity sequence reports its owning column")

            // After a nextval, last_value becomes non-nil.
            _ = try await db.scalarInt("SELECT nextval('\(s).standalone')::int")
            let after = try await SequenceFetcher.fetchAll(client: db.client)
            XCTAssertEqual(after.first { $0.schema == s && $0.name == "standalone" }?.lastValue, 1)
        } catch { await db.dropSchemas(s); throw error }
        await db.dropSchemas(s)
    }
}
