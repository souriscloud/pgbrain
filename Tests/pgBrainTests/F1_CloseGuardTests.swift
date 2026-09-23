import XCTest
@testable import pgBrain

@MainActor
final class F1_CloseGuardTests: XCTestCase {
    private func table(_ name: String) -> TableNode {
        TableNode(schema: "public", name: name, kind: .table, columns: [])
    }

    /// A workspace with one dirty table tab and one scratchpad holding an
    /// open transaction.
    private func fixture() -> (WorkspaceState, dirty: UUID, pad: Notebook, padTab: UUID) {
        let ws = WorkspaceState()
        ws.openTable(table("orders"))
        let dirty = ws.tabs[0]
        dirty.hasPendingChanges = true
        let pad = ws.openScratchpad()
        pad.syncTransaction(.active)
        return (ws, dirty.id, pad, ws.tabs[1].id)
    }

    private final class EventLog {
        var events: [String] = []
    }

    private func prompts(_ log: EventLog, discard: Bool, commit: Bool) -> TabCloseGuard.Prompts {
        TabCloseGuard.Prompts(
            discard: { titles in log.events.append("discard:\(titles.joined(separator: ","))"); return discard },
            transaction: { pad in log.events.append("tx:\(pad.title)"); return commit }
        )
    }

    func testDiscardIsAskedBeforeAnyTransaction() {
        let (ws, dirty, _, padTab) = fixture()
        let log = EventLog()
        let closable = TabCloseGuard.confirmClosing([dirty, padTab], in: ws, prompts: prompts(log, discard: true, commit: true))
        XCTAssertEqual(log.events, ["discard:orders", "tx:Query 1"])
        XCTAssertEqual(closable, [dirty, padTab])
    }

    func testCancellingDiscardNeverTouchesTheTransaction() {
        let (ws, dirty, pad, padTab) = fixture()
        let log = EventLog()
        let closable = TabCloseGuard.confirmClosing([dirty, padTab], in: ws, prompts: prompts(log, discard: false, commit: true))
        XCTAssertEqual(log.events, ["discard:orders"], "transaction prompt (which commits/rolls back) must not run")
        XCTAssertTrue(closable.isEmpty)
        XCTAssertTrue(pad.transaction.isOpen)
    }

    func testCancelledTransactionKeepsOnlyThatTab() {
        let (ws, dirty, _, padTab) = fixture()
        let log = EventLog()
        let closable = TabCloseGuard.confirmClosing([dirty, padTab], in: ws, prompts: prompts(log, discard: true, commit: false))
        XCTAssertEqual(closable, [dirty])
    }

    func testCleanTabsCloseWithoutPrompts() {
        let ws = WorkspaceState()
        ws.openTable(table("a"))
        ws.openScratchpad()
        let log = EventLog()
        let ids = ws.tabs.map(\.id)
        XCTAssertEqual(TabCloseGuard.confirmClosing(ids, in: ws, prompts: prompts(log, discard: false, commit: false)), ids)
        XCTAssertTrue(log.events.isEmpty)
    }

    func testWindowAndQuitAskOnceForAllDirtyTabsThenEachTransaction() {
        let (a, _, _, _) = fixture()
        let (b, _, _, _) = fixture()
        let log = EventLog()
        XCTAssertTrue(TabCloseGuard.confirmClosingAll([a, b], prompts: prompts(log, discard: true, commit: true)))
        XCTAssertEqual(log.events, ["discard:orders,orders", "tx:Query 1", "tx:Query 1"])
    }

    func testQuitCancelledAtDiscardOrAtATransaction() {
        let (a, _, _, _) = fixture()
        let log = EventLog()
        XCTAssertFalse(TabCloseGuard.confirmClosingAll([a], prompts: prompts(log, discard: false, commit: true)))
        XCTAssertEqual(log.events.count, 1)
        XCTAssertFalse(TabCloseGuard.confirmClosingAll([a], prompts: prompts(log, discard: true, commit: false)))
        XCTAssertTrue(TabCloseGuard.confirmClosingAll([WorkspaceState()], prompts: prompts(log, discard: false, commit: false)))
    }

    // MARK: Commit-on-close outcome

    func testCommitOutcome() {
        XCTAssertEqual(Notebook.closeCommitOutcome(reconnected: false, statusAfter: .idle), .committed)
        if case .failed = Notebook.closeCommitOutcome(reconnected: true, statusAfter: .idle) {} else {
            XCTFail("COMMIT on a reopened connection committed nothing")
        }
        if case .failed = Notebook.closeCommitOutcome(reconnected: false, statusAfter: .failed) {} else {
            XCTFail("transaction still open after COMMIT")
        }
    }

    func testWaitSynchronouslyReturnsResultAndTimesOut() {
        let ok = Notebook.waitSynchronously(timeout: 5) { () async throws -> Int in
            try await Task.sleep(nanoseconds: 20_000_000)
            return 7
        }
        XCTAssertEqual(try ok?.get(), 7)
        let slow = Notebook.waitSynchronously(timeout: 0.05) { () async throws -> Int in
            try await Task.sleep(nanoseconds: 2_000_000_000)
            return 1
        }
        XCTAssertNil(slow, "nil = still running when the deadline passed")
    }
}
