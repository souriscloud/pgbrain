import Foundation
import XCTest
@testable import pgBrain

/// Scratchpad runner behaviour on top of the pinned session: affinity,
/// transaction indicator state, manual commit, atomic batches, the
/// double-run guard, Stop, and the result-history cap.
@MainActor
final class E_NotebookRunnerTests: XCTestCase {
    private var db: TestDB?
    private var service: ConnectionService?

    override func tearDown() async throws {
        if let service { QueryHistoryStore.shared.clear(for: service.connection.id) }
        db?.shutdown()
        service = nil
        db = nil
    }

    private func setUp(_ notebook: Notebook) async throws -> ConnectionService {
        let endpoint = try await E_ScratchpadSessionTests.endpointOrSkip()
        let db = try await TestDB.connectOrSkip()
        self.db = db
        let svc = ConnectionService(connection: Connection(name: "e-runner"))
        svc.attachClientForTests(db.client)
        service = svc
        notebook.attach(session: ScratchpadSession(endpoint: endpoint))
        return svc
    }

    @discardableResult
    private func run(_ sql: String, in notebook: Notebook, _ service: ConnectionService) async -> [NotebookResult] {
        let cell = notebook.cells.last(where: { $0.kind == .sql })!
        cell.text = sql
        NotebookRunner.run(cell: cell, selection: nil, notebook: notebook, service: service)
        await notebook.runTask?.value
        return notebook.adjacentResults(after: cell.id).compactMap { notebook.result(id: $0.resultID) }
    }

    private func rows(_ result: NotebookResult?) -> [[String?]]? {
        guard let result, case .success(let q) = result.status else { return nil }
        return q.page.rows
    }

    private func isFailure(_ result: NotebookResult?) -> Bool {
        if let result, case .failure = result.status { return true }
        return false
    }

    func testSettingsPersistAcrossRuns() async throws {
        let notebook = Notebook(title: "affinity")
        let svc = try await setUp(notebook)
        await run("SET application_name = 'e_runner'", in: notebook, svc)
        let results = await run("SHOW application_name", in: notebook, svc)
        XCTAssertEqual(rows(results.last)?.first?.first, "e_runner")
        XCTAssertFalse(notebook.transaction.isOpen)
    }

    func testBeginKeepsTransactionOpenUntilRollback() async throws {
        let notebook = Notebook(title: "tx")
        let svc = try await setUp(notebook)
        await run("BEGIN; SELECT 1 AS x INTO TEMP e_rt", in: notebook, svc)
        XCTAssertEqual(notebook.transaction.status, .active)
        XCTAssertEqual(notebook.transaction.statementCount, 2)
        XCTAssertNotNil(notebook.transaction.startedAt)

        NotebookRunner.endTransaction(commit: false, notebook: notebook, service: svc)
        await notebook.runTask?.value
        XCTAssertEqual(notebook.transaction.status, .idle)

        let after = await run("SELECT count(*) FROM e_rt", in: notebook, svc)
        XCTAssertTrue(isFailure(after.last), "temp table must be gone after ROLLBACK")
    }

    func testFailedTransactionIsReported() async throws {
        let notebook = Notebook(title: "failed")
        let svc = try await setUp(notebook)
        await run("BEGIN; SELECT 1/0", in: notebook, svc)
        XCTAssertEqual(notebook.transaction.status, .failed)
        NotebookRunner.endTransaction(commit: false, notebook: notebook, service: svc)
        await notebook.runTask?.value
        XCTAssertEqual(notebook.transaction.status, .idle)
    }

    func testManualCommitOpensTransactionBeforeWrites() async throws {
        let notebook = Notebook(title: "manual")
        let svc = try await setUp(notebook)
        await run("SELECT 1 AS x INTO TEMP e_manual", in: notebook, svc)
        notebook.autoCommit = false
        await run("SELECT count(*) FROM e_manual", in: notebook, svc)
        XCTAssertFalse(notebook.transaction.isOpen, "reads don't open a transaction")
        await run("INSERT INTO e_manual VALUES (2)", in: notebook, svc)
        XCTAssertEqual(notebook.transaction.status, .active)
        NotebookRunner.endTransaction(commit: false, notebook: notebook, service: svc)
        await notebook.runTask?.value
        let count = await run("SELECT count(*) FROM e_manual", in: notebook, svc)
        XCTAssertEqual(rows(count.last)?.first?.first, "1")
    }

    func testAtomicBatchRollsBackOnFailure() async throws {
        let notebook = Notebook(title: "atomic")
        let svc = try await setUp(notebook)
        await run("SELECT 1 AS x INTO TEMP e_atomic", in: notebook, svc)
        notebook.runAsTransaction = true
        let results = await run("INSERT INTO e_atomic VALUES (2); SELECT 1/0; INSERT INTO e_atomic VALUES (3)", in: notebook, svc)
        XCTAssertEqual(results.count, 3)
        if case .success = results[0].status {} else { XCTFail("first statement ran") }
        XCTAssertTrue(isFailure(results[1]))
        if case .cancelled = results[2].status {} else { XCTFail("third statement never ran") }
        XCTAssertFalse(notebook.transaction.isOpen)
        notebook.runAsTransaction = false
        let count = await run("SELECT count(*) FROM e_atomic", in: notebook, svc)
        XCTAssertEqual(rows(count.last)?.first?.first, "1")
    }

    func testDoubleRunIsIgnoredWhileRunning() async throws {
        let notebook = Notebook(title: "double")
        let svc = try await setUp(notebook)
        let cell = notebook.cells[0]
        cell.text = "SELECT pg_sleep(0.3)"
        NotebookRunner.run(cell: cell, selection: nil, notebook: notebook, service: svc)
        NotebookRunner.run(cell: cell, selection: nil, notebook: notebook, service: svc)
        await notebook.runTask?.value
        XCTAssertEqual(notebook.adjacentResults(after: cell.id).count, 1)
        XCTAssertFalse(notebook.isRunning)
    }

    func testStopCancelsTheRunningStatement() async throws {
        let notebook = Notebook(title: "stop")
        let svc = try await setUp(notebook)
        let cell = notebook.cells[0]
        cell.text = "SELECT pg_sleep(20); SELECT 'never'"
        NotebookRunner.run(cell: cell, selection: nil, notebook: notebook, service: svc)
        try await Task.sleep(nanoseconds: 500_000_000)
        let started = Date()
        notebook.stop()
        await notebook.runTask?.value
        XCTAssertLessThan(Date().timeIntervalSince(started), 5)
        let results = notebook.adjacentResults(after: cell.id).compactMap { notebook.result(id: $0.resultID) }
        XCTAssertEqual(results.count, 2)
        for r in results {
            if case .cancelled = r.status {} else { XCTFail("expected cancelled, got \(r.status)") }
        }
        let alive = await run("SELECT 'alive'", in: notebook, svc)
        XCTAssertEqual(rows(alive.last)?.first?.first, "alive")
    }

    func testSearchPathPickerAppliesToSession() async throws {
        let notebook = Notebook(title: "sp", searchPath: "pg_catalog")
        let svc = try await setUp(notebook)
        let r = await run("SHOW search_path", in: notebook, svc)
        XCTAssertEqual(rows(r.last)?.first?.first, "pg_catalog")
        notebook.searchPath = nil
        let reset = await run("SHOW search_path", in: notebook, svc)
        XCTAssertNotEqual(rows(reset.last)?.first?.first, "pg_catalog")
    }

    func testClosingSessionRollsBack() async throws {
        let notebook = Notebook(title: "close")
        let svc = try await setUp(notebook)
        await run("BEGIN", in: notebook, svc)
        XCTAssertTrue(notebook.transaction.isOpen)
        notebook.closeSession()
        XCTAssertFalse(notebook.transaction.isOpen)
        XCTAssertNil(notebook.session)
    }
}

/// Pure notebook / operations bookkeeping — no database needed.
@MainActor
final class E_NotebookStateTests: XCTestCase {
    func testResultHistoryIsCappedPerCell() {
        let notebook = Notebook(title: "cap")
        let cell = notebook.cells[0]
        var all: [UUID] = []
        for _ in 0..<6 {
            let id = UUID()
            all.append(id)
            notebook.stackResults(after: cell.id, newResultIDs: [id], historyLimit: 3)
            _ = notebook.startResult(id: id, statement: "SELECT 1")
        }
        let kept = notebook.adjacentResults(after: cell.id).map(\.resultID)
        XCTAssertEqual(kept, Array(all.suffix(3)))
        XCTAssertNil(notebook.result(id: all[0]))
    }

    func testBatchLargerThanCapKeepsWholeBatch() {
        let notebook = Notebook(title: "cap")
        let cell = notebook.cells[0]
        let batch = (0..<5).map { _ in UUID() }
        notebook.stackResults(after: cell.id, newResultIDs: [UUID()], historyLimit: 2)
        notebook.stackResults(after: cell.id, newResultIDs: batch, historyLimit: 2)
        XCTAssertEqual(notebook.adjacentResults(after: cell.id).map(\.resultID), batch)
    }

    func testClearResultsKeepsRunningOnes() {
        let notebook = Notebook(title: "clear")
        let cell = notebook.cells[0]
        let done = UUID(), running = UUID()
        notebook.stackResults(after: cell.id, newResultIDs: [done, running])
        notebook.startResult(id: done, statement: "a").status = .cancelled
        _ = notebook.startResult(id: running, statement: "b")
        notebook.clearResults()
        XCTAssertEqual(notebook.adjacentResults(after: cell.id).map(\.resultID), [running])
        XCTAssertTrue(notebook.cells.contains { $0.kind == .sql })
    }

    func testTransactionBookkeeping() {
        let notebook = Notebook(title: "tx")
        let t0 = Date(timeIntervalSince1970: 1000)
        notebook.recordTransaction(.active, now: t0)
        notebook.recordTransaction(.active, now: t0.addingTimeInterval(5))
        XCTAssertEqual(notebook.transaction.statementCount, 2)
        XCTAssertEqual(notebook.transaction.startedAt, t0)
        notebook.recordTransaction(.failed)
        XCTAssertEqual(notebook.transaction.status, .failed)
        notebook.recordTransaction(.idle)
        XCTAssertEqual(notebook.transaction, Notebook.TransactionState())
    }

    func testInitialSearchPath() {
        XCTAssertEqual(Notebook(title: "a", searchPath: "sales").searchPath, "sales")
        XCTAssertNil(Notebook(title: "b", searchPath: "  ").searchPath)
        XCTAssertNil(Notebook(title: "c").searchPath)
    }

    func testImplicitBeginOnlyForWrites() {
        XCTAssertTrue(NotebookRunner.needsImplicitBegin("INSERT INTO t VALUES (1)"))
        XCTAssertTrue(NotebookRunner.needsImplicitBegin("update t set a = 1 where id = 2"))
        XCTAssertTrue(NotebookRunner.needsImplicitBegin("CREATE TABLE x(a int)"))
        XCTAssertFalse(NotebookRunner.needsImplicitBegin("SELECT 1"))
        XCTAssertFalse(NotebookRunner.needsImplicitBegin("BEGIN"))
        XCTAssertFalse(NotebookRunner.needsImplicitBegin("COMMIT"))
        XCTAssertFalse(NotebookRunner.needsImplicitBegin("SET search_path TO x"))
        XCTAssertFalse(NotebookRunner.needsImplicitBegin("VACUUM t"))
    }

    func testOperationsHistoryIsPruned() {
        let ops = OperationsCenter()
        for i in 0..<(OperationsCenter.finishedHistoryLimit + 20) {
            let op = ops.begin(kind: .query, summary: "q\(i)")
            ops.finish(op, status: .succeeded)
        }
        let running = ops.begin(kind: .query, summary: "live")
        XCTAssertLessThanOrEqual(ops.operations.count, OperationsCenter.finishedHistoryLimit + 1)
        XCTAssertTrue(ops.operations.contains { $0 === running })

        ops.pruneFinished(now: Date().addingTimeInterval(OperationsCenter.finishedHistoryAge + 60))
        XCTAssertEqual(ops.operations.count, 1)
        XCTAssertTrue(ops.operations.first === running)
    }
}
