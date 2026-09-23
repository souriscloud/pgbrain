import AppKit
import Foundation
import PostgresNIO

/// Resolves what to run from a given SQL cell, executes via QueryRunner,
/// and feeds results back into the notebook's cell list. Replaces the
/// previous TextKit-attachment-based dispatcher.
@MainActor
enum NotebookRunner {
    static func run(cell: NotebookCell, selection: NSRange?, notebook: Notebook, service: ConnectionService) {
        guard cell.kind == .sql, let client = service.client else { return }

        // Resolve target statements within this cell. Slash-command
        // lines (`\dt`, `\df`, …) get expanded into real SQL before
        // statement splitting so the user can mix `\dt` with normal
        // queries in the same cell.
        let buffer = SlashCommands.translateCell(cell.text)
        let plans: [String]
        if let sel = selection {
            // User selected a range → translate-and-split just that.
            let ns = cell.text as NSString
            guard sel.location + sel.length <= ns.length else { return }
            let slice = SlashCommands.translateCell(ns.substring(with: sel))
            plans = SQLStatementSplitter.split(slice).map { $0.trimmed }
        } else {
            // No selection → run *every* statement in the cell, Jupyter-
            // style. Multi-statement cells get one result widget each.
            let split = SQLStatementSplitter.split(buffer).map { $0.trimmed }
            if !split.isEmpty {
                plans = split
            } else {
                let trimmed = buffer.trimmingCharacters(in: .whitespacesAndNewlines)
                plans = trimmed.isEmpty ? [] : [trimmed]
            }
        }
        guard !plans.isEmpty else { return }

        // DataGrip-style `:name` parameters. Gather the distinct
        // placeholders across every statement about to run; if any lack a
        // remembered value, defer the run and ask the host to collect them
        // — the sheet's confirm handler calls back into `run(...)` with the
        // same cell/selection once the values are stored on the notebook.
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
        // Splice the remembered values into each statement before executing.
        let resolvedPlans = neededNames.isEmpty
            ? plans
            : plans.map { ScratchpadParameters.substitute($0, with: notebook.parameters) }

        // Production-destructive guardrail.
        if service.connection.isProduction {
            let destructive = resolvedPlans.contains {
                let v = SQLSafety.classify($0)
                return v == .destructiveUnscoped || v == .ddl
            }
            if destructive, !confirmProductionRun(plans: resolvedPlans, service: service) { return }
        }

        notebook.runningCellID = cell.id

        // Each run STACKS: fresh result widgets are appended after any results
        // already under this cell, and the prior ones collapse. Re-running the
        // cell accumulates a history instead of replacing it.
        let ids = resolvedPlans.map { _ in UUID() }
        notebook.stackResults(after: cell.id, newResultIDs: ids)

        // Mark each result as running before kicking off the async pipeline so
        // the SwiftUI cells flip to "Running…" immediately. The current run's
        // widgets start expanded (it's what you just asked for); a big batch
        // (>3) starts collapsed to stay scannable.
        let collapseAll = resolvedPlans.count > 3
        for (sql, id) in zip(resolvedPlans, ids) {
            let r = notebook.startResult(id: id, statement: sql)
            r.isCollapsed = collapseAll
        }

        // Transactional path: all statements on one connection inside
        // BEGIN/COMMIT. The first failure short-circuits and rolls back
        // the whole batch; remaining widgets get marked `.cancelled`.
        if notebook.runAsTransaction && resolvedPlans.count > 1 {
            Task { @MainActor in
                defer { notebook.runningCellID = nil }
                await runTransactional(plans: resolvedPlans, ids: ids, notebook: notebook, service: service, client: client)
            }
            return
        }

        Task { @MainActor in
            defer { notebook.runningCellID = nil }
            var schemaTouched = false
            for (sql, id) in zip(resolvedPlans, ids) {
                let op = service.operations.begin(kind: .query, summary: QueryRunner.summary(of: sql))
                let result = notebook.startResult(id: id, statement: sql)
                result.isCollapsed = collapseAll
                let started = Date()
                do {
                    let qr = try await QueryRunner.run(
                        sql, on: client,
                        operationID: op.id, tracker: service.operations,
                        searchPath: notebook.searchPath
                    )
                    result.status = .success(qr)
                    result.finishedAt = Date()
                    service.operations.finish(op, status: .succeeded)
                    if Self.isSchemaChangingSQL(sql) { schemaTouched = true }
                    QueryHistoryStore.shared.record(
                        connectionID: service.connection.id,
                        sql: sql, startedAt: started,
                        elapsedSec: Date().timeIntervalSince(started),
                        success: true, errorMessage: nil,
                        rowsAffected: qr.rowsAffected
                    )
                } catch is CancellationError {
                    result.status = .cancelled
                    result.finishedAt = Date()
                    service.operations.finish(op, status: .cancelled)
                    QueryHistoryStore.shared.record(
                        connectionID: service.connection.id,
                        sql: sql, startedAt: started,
                        elapsedSec: Date().timeIntervalSince(started),
                        success: false, errorMessage: "Cancelled",
                        rowsAffected: nil
                    )
                } catch {
                    let message = PostgresErrorMessage.describe(error)
                    result.status = .failure(message)
                    result.finishedAt = Date()
                    service.operations.finish(op, status: .failed(message))
                    QueryHistoryStore.shared.record(
                        connectionID: service.connection.id,
                        sql: sql, startedAt: started,
                        elapsedSec: Date().timeIntervalSince(started),
                        success: false, errorMessage: message,
                        rowsAffected: nil
                    )
                }
            }
            // A successful CREATE / DROP / ALTER / COMMENT can add or remove
            // sidebar objects (tables, functions, schemas) — refresh so the
            // tree reflects it without a reconnect.
            if schemaTouched { await service.loadSchema() }
        }
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

    /// Single-connection BEGIN/COMMIT batch. Walks `plans` sequentially
    /// on one checked-out connection. First failure short-circuits the
    /// loop and issues ROLLBACK; statements that never ran get marked
    /// `.cancelled` so the user can see exactly where the failure was.
    @MainActor
    private static func runTransactional(
        plans: [String], ids: [UUID],
        notebook: Notebook, service: ConnectionService,
        client: PostgresClient
    ) async {
        let op = service.operations.begin(kind: .update, summary: "Transaction (\(plans.count) statements)")
        let started = Date()
        var failureMessage: String?
        var failedAt: Int = plans.count
        do {
            try await client.withConnection { conn in
                _ = try await conn.query(PostgresQuery(unsafeSQL: "BEGIN"), logger: pgbrainQuietLogger)
                if let sp = notebook.searchPath {
                    _ = try await conn.query(
                        PostgresQuery(unsafeSQL: "SET LOCAL search_path TO \(SQLIdent.quote(sp))"),
                        logger: pgbrainQuietLogger
                    )
                }
                for (i, (sql, id)) in zip(plans, ids).enumerated() {
                    let stmtStarted = Date()
                    let result = await MainActor.run { notebook.startResult(id: id, statement: sql) }
                    do {
                        let qr = try await QueryRunner.runOnConnection(sql, on: conn)
                        await MainActor.run {
                            result.status = .success(qr)
                            result.finishedAt = Date()
                        }
                        QueryHistoryStore.shared.record(
                            connectionID: service.connection.id,
                            sql: sql, startedAt: stmtStarted,
                            elapsedSec: Date().timeIntervalSince(stmtStarted),
                            success: true, errorMessage: nil,
                            rowsAffected: qr.rowsAffected
                        )
                    } catch {
                        let msg = PostgresErrorMessage.describe(error)
                        failureMessage = msg
                        failedAt = i
                        await MainActor.run {
                            result.status = .failure(msg)
                            result.finishedAt = Date()
                        }
                        QueryHistoryStore.shared.record(
                            connectionID: service.connection.id,
                            sql: sql, startedAt: stmtStarted,
                            elapsedSec: Date().timeIntervalSince(stmtStarted),
                            success: false, errorMessage: msg,
                            rowsAffected: nil
                        )
                        break
                    }
                }
                // Commit on full success, rollback on any failure.
                if failureMessage == nil {
                    _ = try await conn.query(PostgresQuery(unsafeSQL: "COMMIT"), logger: pgbrainQuietLogger)
                } else {
                    _ = try? await conn.query(PostgresQuery(unsafeSQL: "ROLLBACK"), logger: pgbrainQuietLogger)
                }
            }
            // Mark the never-ran widgets so the user sees the cutoff.
            for i in (failedAt + 1)..<plans.count {
                let r = await MainActor.run { notebook.startResult(id: ids[i], statement: plans[i]) }
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
            _ = started
        } catch {
            let msg = PostgresErrorMessage.describe(error)
            service.operations.finish(op, status: .failed(msg))
            // Mark every widget that never resolved.
            for id in ids {
                guard let r = notebook.result(id: id), case .running = r.status else { continue }
                r.status = .failure(msg)
                r.finishedAt = Date()
            }
        }
    }

    @MainActor
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
