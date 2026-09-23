import AppKit
import Foundation
import PostgresNIO

/// Resolves what to run from a given SQL cell, executes it on the tab's
/// pinned `ScratchpadSession`, and feeds results back into the notebook's
/// cell list. Falls back to per-statement pooled execution only when the
/// session can't authenticate (see `Notebook.sessionUnavailableReason`).
@MainActor
enum NotebookRunner {
    static func run(cell: NotebookCell, selection: NSRange?, notebook: Notebook, service: ConnectionService) {
        guard cell.kind == .sql, let client = service.client else { return }
        // One run per tab at a time: the session executes serially anyway,
        // and a second ⌘↩ while the first is in flight is almost always a
        // double-press, not a request to run it twice.
        guard !notebook.isRunning else {
            NSSound.beep()
            return
        }

        // Slash-command lines (`\dt`, `\df`, …) get expanded into real SQL
        // before statement splitting so the user can mix `\dt` with normal
        // queries in the same cell.
        let plans: [String]
        if let sel = selection {
            let ns = cell.text as NSString
            guard sel.location + sel.length <= ns.length else { return }
            let slice = SlashCommands.translateCell(ns.substring(with: sel))
            plans = SQLStatementSplitter.split(slice).map { $0.trimmed }
        } else {
            // No selection → run *every* statement in the cell, Jupyter-
            // style. Multi-statement cells get one result widget each.
            let buffer = SlashCommands.translateCell(cell.text)
            let split = SQLStatementSplitter.split(buffer).map { $0.trimmed }
            if !split.isEmpty {
                plans = split
            } else {
                let trimmed = buffer.trimmingCharacters(in: .whitespacesAndNewlines)
                plans = trimmed.isEmpty ? [] : [trimmed]
            }
        }
        guard !plans.isEmpty else { return }

        // DataGrip-style `:name` parameters. If any lack a remembered value,
        // defer the run and ask the host to collect them — the sheet's
        // confirm handler calls back into `run(...)` once they're stored.
        let neededNames = plans.reduce(into: [String]()) { acc, sql in
            for name in ScratchpadParameters.names(in: sql) where !acc.contains(name) {
                acc.append(name)
            }
        }
        let unfilled = neededNames.filter { (notebook.parameters[$0]?.isEmpty ?? true) }
        if !unfilled.isEmpty {
            notebook.requestedParameters = Notebook.ParameterRequest(
                names: neededNames, cellID: cell.id, selection: selection
            )
            return
        }
        let resolvedPlans = neededNames.isEmpty
            ? plans
            : plans.map { ScratchpadParameters.substitute($0, with: notebook.parameters) }

        if service.connection.isProduction {
            let destructive = resolvedPlans.contains {
                let v = SQLSafety.classify($0)
                return v == .destructiveUnscoped || v == .ddl
            }
            if destructive, !confirmProductionRun(plans: resolvedPlans, service: service) { return }
        }

        notebook.runningCellID = cell.id

        // Each run STACKS: fresh result widgets are appended after any results
        // already under this cell, and the prior ones collapse.
        let ids = resolvedPlans.map { _ in UUID() }
        notebook.stackResults(after: cell.id, newResultIDs: ids)
        // A big batch (>3) starts collapsed to stay scannable.
        let collapseAll = resolvedPlans.count > 3
        let results = zip(resolvedPlans, ids).map { sql, id in
            let r = notebook.startResult(id: id, statement: sql)
            r.isCollapsed = collapseAll
            return r
        }

        let weak = WeakNotebook(notebook)
        notebook.runTask = Task { @MainActor in
            await execute(plans: resolvedPlans, results: results, notebook: weak, service: service, client: client)
            weak.value?.runningCellID = nil
            weak.value?.runTask = nil
            weak.value?.currentTicket = nil
        }
    }

    /// Commit / Roll Back buttons. Runs on the session so it ends the
    /// transaction the user actually opened.
    static func endTransaction(commit: Bool, notebook: Notebook, service: ConnectionService) {
        guard !notebook.isRunning, let session = notebook.session else { return }
        let weak = WeakNotebook(notebook)
        notebook.runTask = Task { @MainActor in
            do {
                _ = try await session.run(commit ? "COMMIT" : "ROLLBACK", rowLimit: 1)
            } catch {
                service.toasts.show(.error, "\(commit ? "COMMIT" : "ROLLBACK") failed — \(describe(error))")
            }
            guard let notebook = weak.value else { return }
            notebook.syncTransaction(session.transactionStatus)
            notebook.runTask = nil
            if commit, notebook.schemaChangedInTransaction {
                notebook.schemaChangedInTransaction = false
                await service.loadSchema()
            }
            notebook.schemaChangedInTransaction = false
        }
    }

    /// EXPLAIN through the tab's session when it has one, so the plan sees
    /// the same temp tables, settings and search_path as a run would.
    static func explain(sql: String, analyze: Bool, notebook: Notebook, service: ConnectionService) async -> Result<ExplainNode, Error> {
        do {
            if let session = try await usableSession(WeakNotebook(notebook), service: service) {
                try await applySearchPath(notebook: WeakNotebook(notebook), session: session)
                return .success(try await Explain.run(sql: sql, analyze: analyze, session: session))
            }
            guard let client = service.client else { return .failure(Explain.ExplainError.empty) }
            return .success(try await Explain.run(sql: sql, analyze: analyze, on: client))
        } catch {
            return .failure(error)
        }
    }

    // MARK: - Execution

    private enum Batch {
        case none, transaction, savepoint
    }

    private static let atomicSavepoint = "pgbrain_atomic"

    private static func execute(
        plans: [String], results: [NotebookResult],
        notebook weak: WeakNotebook, service: ConnectionService, client: PostgresClient
    ) async {
        let session: ScratchpadSession?
        do {
            session = try await usableSession(weak, service: service)
        } catch {
            fail(results, message: describe(error))
            return
        }
        guard let session else {
            await executePooled(plans: plans, results: results, notebook: weak, service: service, client: client)
            return
        }

        let atomic = (weak.value?.runAsTransaction ?? false) && plans.count > 1
        var batch = Batch.none
        var schemaTouched = false
        var stopAt: Int?

        do {
            try await applySearchPath(notebook: weak, session: session)
            if atomic {
                switch session.transactionStatus {
                case .idle:
                    _ = try await session.run("BEGIN", rowLimit: 1)
                    batch = .transaction
                case .active:
                    _ = try await session.run("SAVEPOINT \(atomicSavepoint)", rowLimit: 1)
                    batch = .savepoint
                case .failed:
                    break
                }
            }
        } catch {
            if let notebook = weak.value, fallBackIfUnsupported(error, notebook: notebook, service: service) {
                await executePooled(plans: plans, results: results, notebook: weak, service: service, client: client)
                return
            }
            fail(results, message: describe(error))
            weak.value?.syncTransaction(session.transactionStatus)
            return
        }

        for (index, (sql, result)) in zip(plans, results).enumerated() {
            if Task.isCancelled || weak.value == nil {
                stopAt = index
                break
            }
            let outcome = await runStatement(sql, result: result, session: session, notebook: weak, service: service)
            switch outcome {
            case .succeeded(let ddl):
                if ddl { schemaTouched = true }
            case .failed:
                if batch != .none { stopAt = index + 1 }
            case .cancelled:
                stopAt = index + 1
            case .unsupported:
                await executePooled(plans: Array(plans[index...]), results: Array(results[index...]),
                                    notebook: weak, service: service, client: client)
                return
            }
            if let stop = stopAt, stop > index { break }
        }

        if let stop = stopAt {
            for r in results[stop...] where r.isRunning {
                r.status = .cancelled
                r.finishedAt = Date()
            }
        }

        let batchFailed = stopAt != nil
        switch batch {
        case .none:
            break
        case .transaction:
            _ = try? await session.run(batchFailed ? "ROLLBACK" : "COMMIT", rowLimit: 1)
        case .savepoint:
            if batchFailed {
                _ = try? await session.run("ROLLBACK TO SAVEPOINT \(atomicSavepoint)", rowLimit: 1)
            }
            _ = try? await session.run("RELEASE SAVEPOINT \(atomicSavepoint)", rowLimit: 1)
        }
        if batch == .transaction, batchFailed { schemaTouched = false }
        weak.value?.syncTransaction(session.transactionStatus)
        let deferredRefresh = weak.value?.schemaChangedInTransaction ?? false

        // A successful CREATE / DROP / ALTER / COMMENT can add or remove
        // sidebar objects. Inside an open transaction the change is invisible
        // to the pool until COMMIT, so defer the refresh until then.
        let idle = session.transactionStatus == .idle
        if (schemaTouched || deferredRefresh) && idle {
            weak.value?.schemaChangedInTransaction = false
            await service.loadSchema()
        } else if schemaTouched {
            weak.value?.schemaChangedInTransaction = true
        }
    }

    private enum StatementOutcome {
        case succeeded(ddl: Bool)
        case failed
        case cancelled
        case unsupported
    }

    private static func runStatement(
        _ sql: String, result: NotebookResult, session: ScratchpadSession,
        notebook weak: WeakNotebook, service: ConnectionService
    ) async -> StatementOutcome {
        let op = service.operations.begin(kind: .query, summary: QueryRunner.summary(of: sql))
        let ticket = session.makeTicket()
        op.backendPID = session.backendPID
        op.cancellationHandler = { await session.cancel(ticket) }
        weak.value?.currentTicket = ticket
        result.startedAt = Date()
        let started = Date()
        defer { weak.value?.currentTicket = nil }

        do {
            if let notebook = weak.value, !notebook.autoCommit,
               session.transactionStatus == .idle, needsImplicitBegin(sql) {
                _ = try await session.run("BEGIN", rowLimit: 1)
            }
            let limit = QueryRunner.defaultRowLimit
            let wireSQL = SQLSafety.classify(sql) == .readOnly ? QueryRunner.applyAutoLimit(sql, cap: limit) : sql
            let response = try await session.run(wireSQL, rowLimit: limit, ticket: ticket)
            result.status = .success(response.result)
            result.finishedAt = Date()
            op.backendPID = session.backendPID
            service.operations.finish(op, status: .succeeded)
            if let notebook = weak.value {
                notebook.recordTransaction(response.transaction)
                notebook.sessionNotice = response.reconnected
                    ? "Reconnected — the server had closed the previous session, so its temp tables, settings and any open transaction are gone."
                    : nil
            }
            record(sql, started: started, service: service, success: true, error: nil, rows: response.result.rowsAffected)
            return .succeeded(ddl: isSchemaChangingSQL(sql))
        } catch {
            result.finishedAt = Date()
            weak.value?.recordTransaction(session.transactionStatus)
            if isCancellation(error) {
                result.status = .cancelled
                service.operations.finish(op, status: .cancelled)
                record(sql, started: started, service: service, success: false, error: "Cancelled", rows: nil)
                return .cancelled
            }
            if let notebook = weak.value, fallBackIfUnsupported(error, notebook: notebook, service: service) {
                result.status = .running
                result.finishedAt = nil
                service.operations.finish(op, status: .cancelled)
                return .unsupported
            }
            let message = describe(error)
            if case PGWireError.connectionClosed = error {
                weak.value?.syncTransaction(.idle)
                weak.value?.appliedSearchPath = .none
            }
            result.status = .failure(message)
            service.operations.finish(op, status: .failed(message))
            record(sql, started: started, service: service, success: false, error: message, rows: nil)
            return .failed
        }
    }

    /// Per-statement pooled execution — the pre-session behaviour, kept only
    /// for servers the wire session can't authenticate against.
    private static func executePooled(
        plans: [String], results: [NotebookResult],
        notebook weak: WeakNotebook, service: ConnectionService, client: PostgresClient
    ) async {
        guard let runAsTransaction = weak.value?.runAsTransaction else { return }
        let searchPath = weak.value?.searchPath
        if runAsTransaction && plans.count > 1 {
            await runPooledTransaction(plans: plans, results: results, searchPath: searchPath, service: service, client: client)
            return
        }
        var schemaTouched = false
        for (index, (sql, result)) in zip(plans, results).enumerated() {
            if Task.isCancelled || weak.value == nil {
                for r in results[index...] where r.isRunning {
                    r.status = .cancelled
                    r.finishedAt = Date()
                }
                break
            }
            let op = service.operations.begin(kind: .query, summary: QueryRunner.summary(of: sql))
            result.startedAt = Date()
            let started = Date()
            do {
                let qr = try await QueryRunner.run(
                    sql, on: client,
                    operationID: op.id, tracker: service.operations,
                    searchPath: searchPath
                )
                result.status = .success(qr)
                result.finishedAt = Date()
                service.operations.finish(op, status: .succeeded)
                if isSchemaChangingSQL(sql) { schemaTouched = true }
                record(sql, started: started, service: service, success: true, error: nil, rows: qr.rowsAffected)
            } catch {
                result.finishedAt = Date()
                if isCancellation(error) {
                    result.status = .cancelled
                    service.operations.finish(op, status: .cancelled)
                    record(sql, started: started, service: service, success: false, error: "Cancelled", rows: nil)
                } else {
                    let message = describe(error)
                    result.status = .failure(message)
                    service.operations.finish(op, status: .failed(message))
                    record(sql, started: started, service: service, success: false, error: message, rows: nil)
                }
            }
        }
        if schemaTouched { await service.loadSchema() }
    }

    /// Pooled BEGIN/COMMIT batch on one checked-out connection. The first
    /// failure short-circuits and rolls back; statements that never ran are
    /// marked cancelled so the cutoff is visible.
    private static func runPooledTransaction(
        plans: [String], results: [NotebookResult], searchPath: String?,
        service: ConnectionService, client: PostgresClient
    ) async {
        let op = service.operations.begin(kind: .update, summary: "Transaction (\(plans.count) statements)")
        var failureMessage: String?
        var failedAt = plans.count
        do {
            try await client.withConnection { conn in
                _ = try await conn.query(PostgresQuery(unsafeSQL: "BEGIN"), logger: pgbrainQuietLogger)
                if let sp = searchPath {
                    _ = try await conn.query(
                        PostgresQuery(unsafeSQL: "SET LOCAL search_path TO \(SQLIdent.quote(sp))"),
                        logger: pgbrainQuietLogger
                    )
                }
                for (i, (sql, result)) in zip(plans, results).enumerated() {
                    let started = Date()
                    do {
                        let qr = try await QueryRunner.runOnConnection(sql, on: conn)
                        await MainActor.run {
                            result.status = .success(qr)
                            result.finishedAt = Date()
                        }
                        record(sql, started: started, service: service, success: true, error: nil, rows: qr.rowsAffected)
                    } catch {
                        let msg = PostgresErrorMessage.describe(error)
                        failureMessage = msg
                        failedAt = i
                        await MainActor.run {
                            result.status = .failure(msg)
                            result.finishedAt = Date()
                        }
                        record(sql, started: started, service: service, success: false, error: msg, rows: nil)
                        break
                    }
                }
                if failureMessage == nil {
                    _ = try await conn.query(PostgresQuery(unsafeSQL: "COMMIT"), logger: pgbrainQuietLogger)
                } else {
                    _ = try? await conn.query(PostgresQuery(unsafeSQL: "ROLLBACK"), logger: pgbrainQuietLogger)
                }
            }
            for r in results.dropFirst(failedAt + 1) {
                r.status = .cancelled
                r.finishedAt = Date()
            }
            if let msg = failureMessage {
                service.operations.finish(op, status: .failed("rolled back — \(msg)"))
            } else {
                service.operations.finish(op, status: .succeeded)
                if plans.contains(where: { isSchemaChangingSQL($0) }) {
                    await service.loadSchema()
                }
            }
        } catch {
            let msg = PostgresErrorMessage.describe(error)
            service.operations.finish(op, status: .failed(msg))
            fail(results, message: msg)
        }
    }

    // MARK: - Session plumbing

    /// The tab's live session, opening one on first use; nil when the tab
    /// has fallen back to pooled execution.
    private static func usableSession(_ weak: WeakNotebook, service: ConnectionService) async throws -> ScratchpadSession? {
        guard let reason = weak.value.map({ $0.sessionUnavailableReason }), reason == nil else { return nil }
        if let existing = weak.value?.session, !existing.isClosed { return existing }
        let endpoint = try await endpoint(for: service)
        guard let notebook = weak.value else { return nil }
        let session = ScratchpadSession(endpoint: endpoint)
        notebook.attach(session: session)
        return session
    }

    static func endpoint(for service: ConnectionService) async throws -> PGWireEndpoint {
        let c = service.connection
        let target = try await ConnectionService.openEndpoint(for: c, owner: service.scratchpadTunnelOwner)
        let password = await Keychain.passwordAsync(for: c.id)
        var endpoint = PGWireEndpoint(
            host: target.host,
            port: target.port,
            tlsServerName: ConnectionService.tlsServerName(for: c),
            username: c.username,
            password: (password?.isEmpty ?? true) ? nil : password,
            database: c.database.isEmpty ? nil : c.database,
            sslMode: c.sslMode
        )
        endpoint.tls = try ConnectionService.tlsConfiguration(for: c)
        endpoint.startupParameters = c.startupParameters(applicationName: "pgBrain")
        return endpoint
    }

    /// Bring the session's search_path in line with the picker, only when the
    /// picker changed since it was last applied — a hand-typed
    /// `SET search_path` otherwise stays in effect.
    private static func applySearchPath(notebook weak: WeakNotebook, session: ScratchpadSession) async throws {
        guard let current = weak.value.map({ $0.appliedSearchPath }), let desired = weak.value.map({ $0.searchPath }) else { return }
        if case .some(let applied) = current, applied == desired { return }
        guard session.transactionStatus != .failed else { return }
        if let schema = desired {
            _ = try await session.run("SET search_path TO \(SQLIdent.quote(schema))", rowLimit: 1)
        } else if current != nil {
            _ = try await session.run("RESET search_path", rowLimit: 1)
        }
        weak.value?.appliedSearchPath = .some(desired)
    }

    private static func fallBackIfUnsupported(_ error: any Error, notebook: Notebook, service: ConnectionService) -> Bool {
        guard case PGWireError.unsupportedAuthentication(let method) = error else { return false }
        notebook.sessionUnavailableReason = "Pinned session unavailable (\(method)) — statements run on pooled connections, so SET, temp tables and BEGIN don't carry over between runs."
        notebook.sessionNotice = notebook.sessionUnavailableReason
        notebook.closeSession()
        Log.connection.notice("Scratchpad session fell back to the pool: \(method, privacy: .public)")
        return true
    }

    /// Statements that should open a transaction in manual-commit mode:
    /// anything that changes data or schema, but not transaction control
    /// itself (which the user is already managing) or plain reads.
    static func needsImplicitBegin(_ sql: String) -> Bool {
        let first = SQLSafety.tokens(in: sql).first?.lowercased() ?? ""
        let control: Set<String> = [
            "begin", "start", "commit", "end", "rollback", "abort", "savepoint",
            "release", "prepare", "set", "reset", "show", "vacuum", "discard",
            "listen", "unlisten", "notify", "checkpoint", "load",
        ]
        if control.contains(first) { return false }
        return SQLSafety.classify(sql) != .readOnly
    }

    private static func isCancellation(_ error: any Error) -> Bool {
        if error is CancellationError { return true }
        if let server = error as? PGServerError, server.isQueryCanceled { return true }
        if case PGWireError.cancelled = error { return true }
        if case PGWireError.sessionClosed = error { return true }
        return false
    }

    private static func describe(_ error: any Error) -> String {
        if let server = error as? PGServerError { return server.errorDescription ?? server.message }
        if let wire = error as? PGWireError { return wire.errorDescription ?? "\(wire)" }
        return PostgresErrorMessage.describe(error)
    }

    private static func fail(_ results: [NotebookResult], message: String) {
        for r in results where r.isRunning {
            r.status = .failure(message)
            r.finishedAt = Date()
        }
    }

    private static func record(_ sql: String, started: Date, service: ConnectionService, success: Bool, error: String?, rows: Int?) {
        QueryHistoryStore.shared.record(
            connectionID: service.connection.id,
            sql: sql, startedAt: started,
            elapsedSec: Date().timeIntervalSince(started),
            success: success, errorMessage: error,
            rowsAffected: rows
        )
    }

    /// Returns true when `sql`'s leading keyword is DDL that can change what
    /// the sidebar shows. Comment-only / whitespace prefixes are skipped.
    static func isSchemaChangingSQL(_ sql: String) -> Bool {
        var s = sql.trimmingCharacters(in: .whitespacesAndNewlines)
        // Strip leading line/block comments so "-- note\nCREATE …" still counts.
        while true {
            if s.hasPrefix("--") {
                if let nl = s.firstIndex(of: "\n") { s = String(s[s.index(after: nl)...]).trimmingCharacters(in: .whitespacesAndNewlines); continue }
                return false
            }
            if s.hasPrefix("/*"), let close = s.range(of: "*/") {
                s = String(s[close.upperBound...]).trimmingCharacters(in: .whitespacesAndNewlines); continue
            }
            break
        }
        let head = s.prefix(while: { $0.isLetter }).lowercased()
        return ["create", "drop", "alter", "comment"].contains(head)
    }

    private static func confirmProductionRun(plans: [String], service: ConnectionService) -> Bool {
        let preview = plans.prefix(3).joined(separator: "\n\n").prefix(360)
        let alert = NSAlert()
        alert.messageText = "Run on production?"
        alert.informativeText = """
            The connection "\(service.connection.name)" is marked PRODUCTION and \
            at least one statement in this batch is destructive or DDL.

            \(preview)
            """
        alert.alertStyle = .critical
        alert.addButton(withTitle: "Run on PROD")
        alert.addButton(withTitle: "Cancel")
        return alert.runModal() == .alertFirstButtonReturn
    }
}

/// Lets a run's task reach the notebook without keeping it alive: closing the
/// tab must release the notebook (whose deinit closes the session) even while
/// a long statement is still running.
@MainActor
final class WeakNotebook {
    weak var value: Notebook?
    init(_ notebook: Notebook) { value = notebook }
}

private extension NotebookResult {
    var isRunning: Bool {
        if case .running = status { return true }
        return false
    }
}
