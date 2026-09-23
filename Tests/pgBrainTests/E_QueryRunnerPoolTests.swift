import Foundation
import XCTest
@testable import pgBrain

/// The pooled `QueryRunner.run` path (function runner, pooled fallback):
/// write statements stream under the row cap and still report their tag.
final class E_QueryRunnerPoolTests: XCTestCase {
    func testWriteReturningIsCappedAndTagged() async throws {
        let db = try await TestDB.connectOrSkip()
        defer { db.shutdown() }
        let table = TestDB.uniqueTag()
        try await db.exec("CREATE TABLE public.\(table) (x int)")
        do {
            let r = try await QueryRunner.run(
                "INSERT INTO public.\(table) SELECT g FROM generate_series(1, 3000) g RETURNING x",
                on: db.client, limit: 50
            )
            XCTAssertEqual(r.page.rows.count, 50)
            XCTAssertTrue(r.page.truncated)
            XCTAssertEqual(r.commandTag, "INSERT 0 3000")
            XCTAssertEqual(r.rowsAffected, 3000)
        } catch {
            try? await db.exec("DROP TABLE public.\(table)")
            throw error
        }
        try await db.exec("DROP TABLE public.\(table)")
    }

    func testCancelGateRunsOnlyWhileOpen() async {
        let gate = CancelGate()
        let fired = Counter()
        await gate.fire { await fired.bump() }
        await gate.close()
        await gate.fire { await fired.bump() }
        let count = await fired.value
        XCTAssertEqual(count, 1)
    }

    private actor Counter {
        var value = 0
        func bump() { value += 1 }
    }
}
