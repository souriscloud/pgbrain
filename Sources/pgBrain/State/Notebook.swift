import AppKit
import Foundation
import Observation
import Synchronization

/// Cell-based notebook scratchpad. The earlier TextKit-attachment design
/// fell over hard because `NSTextAttachmentViewProvider` refuses to render
/// inline widgets through our NSTextView setup — so the model is now a flat
/// array of cells, each either SQL text the user types or a result widget
/// produced by running a SQL cell.
///
/// What's lost: cross-cell text selection (which the attachment plan was
/// supposed to give us). What's gained: the widget actually renders, the
/// architecture maps to SwiftUI cleanly, and per-cell run/replace
/// semantics are obvious in code.
@MainActor
@Observable
final class Notebook: Identifiable {
    let id = UUID()
    var title: String
    /// Schema this notebook scopes its queries to. `nil` means "use the
    /// connection's default `search_path`" (typically `"$user", public`).
    /// The runner applies it to the tab's pinned session whenever it differs
    /// from what was last applied there, so a `SET search_path` the user
    /// types by hand stays in effect until the picker changes.
    var searchPath: String?
    /// Document is a flat ordered sequence of cells. Always starts and ends
    /// with at least one SQL cell so the user has somewhere to type.
    private(set) var cells: [NotebookCell] = []
    /// Result records keyed by UUID. Each `NotebookCell.kind == .result`
    /// points at one of these. Stored out-of-band so cell-list mutations
    /// (insert/remove) don't disturb status updates landing on the result.
    private(set) var results: [UUID: NotebookResult] = [:]
    /// ID of the SQL cell currently running. Powers a green-border outline
    /// in the editor while a run is in flight.
    var runningCellID: UUID?
    /// Pulse: SQL string the user wants explained. `NotebookView`
    /// catches the change, opens the EXPLAIN sheet, and clears it.
    /// Same consume-on-use contract as the tab `requested*` flags.
    var requestedExplainSQL: String?
    /// Pulse: ask the host to open the result-diff sheet on the
    /// last two successful results in this notebook.
    var requestedDiffLastTwo: Bool = false
    /// When true, every multi-statement cell run is wrapped in one
    /// BEGIN/COMMIT (or a savepoint inside an already-open transaction) so a
    /// partial-batch failure rolls the whole batch back.
    var runAsTransaction: Bool = false
    /// DataGrip's Auto / Manual commit. In manual mode the runner opens a
    /// transaction before the first data-changing statement, and nothing is
    /// committed until the user presses Commit.
    var autoCommit: Bool = true
    /// Server-reported transaction state of the pinned session, plus the
    /// bookkeeping the toolbar indicator shows.
    var transaction = TransactionState()
    /// One-line heads-up about the session itself (reconnected, fell back to
    /// pooled execution, …).
    var sessionNotice: String?
    /// Why the pinned session can't be used on this connection (e.g. an
    /// authentication method only PostgresNIO speaks). The runner then falls
    /// back to per-statement pooled execution.
    var sessionUnavailableReason: String?

    struct TransactionState: Equatable {
        var status: ScratchpadSession.TransactionStatus = .idle
        var startedAt: Date?
        var statementCount = 0

        var isOpen: Bool { status != .idle }
    }

    /// The in-flight run (all statements of one cell invocation). Cancelled
    /// by Stop and when the tab's session is closed.
    @ObservationIgnored var runTask: Task<Void, Never>?
    /// Ticket of the statement currently on the wire, so Stop can cancel
    /// exactly that statement.
    @ObservationIgnored var currentTicket: ScratchpadSession.Ticket?
    /// The `searchPath` value last applied to the current session; `.none`
    /// means nothing applied yet (fresh session).
    @ObservationIgnored var appliedSearchPath: String??
    /// DDL ran inside a still-open transaction; the sidebar refresh waits for
    /// COMMIT because the pool can't see the change before then.
    @ObservationIgnored var schemaChangedInTransaction = false
    private let sessionBox = SessionBox()
    /// DataGrip-style `:name` query-parameter values, remembered across
    /// re-runs so the user fills a placeholder once and subsequent runs
    /// reuse the value. Keyed by parameter name (without the leading `:`).
    var parameters: [String: String] = [:]
    /// Pulse: when set, `NotebookView` opens the parameter-collection
    /// sheet and, on confirm, re-runs the captured cell. Consume-on-use,
    /// same contract as the other `requested*` pulses.
    var requestedParameters: ParameterRequest?

    /// A pending parameter prompt: which placeholders to collect and the
    /// run to replay once they're filled.
    struct ParameterRequest: Identifiable {
        let id = UUID()
        let names: [String]
        let cellID: UUID
        let selection: NSRange?
    }

    /// `searchPath` presets the schema scope (e.g. "New query here" on a
    /// schema in the sidebar); nil or blank leaves the server default.
    init(title: String, searchPath: String? = nil) {
        self.title = title
        let trimmed = searchPath?.trimmingCharacters(in: .whitespaces)
        self.searchPath = (trimmed?.isEmpty ?? true) ? nil : trimmed
        // Seed with one empty SQL cell so the user can immediately type.
        self.cells = [NotebookCell(kind: .sql)]
    }

    deinit {
        sessionBox.close()
    }

    // MARK: - Session

    /// The tab's pinned server session, if one has been opened.
    var session: ScratchpadSession? { sessionBox.current }

    func attach(session: ScratchpadSession) {
        sessionBox.replace(with: session)
        appliedSearchPath = .none
    }

    var isRunning: Bool { runningCellID != nil }

    /// Stop the running statement and the rest of its batch.
    func stop() {
        if let ticket = currentTicket, let session {
            Task { await session.cancel(ticket) }
        }
        runTask?.cancel()
    }

    /// Drop the pinned session: cancels anything running and closes the
    /// connection, which makes the server roll back an open transaction.
    /// The next run opens a fresh session.
    func closeSession() {
        runTask?.cancel()
        runTask = nil
        currentTicket = nil
        sessionBox.close()
        appliedSearchPath = .none
        transaction = TransactionState()
    }

    /// Fold the status the server reported after a statement into the
    /// indicator's bookkeeping.
    func recordTransaction(_ status: ScratchpadSession.TransactionStatus, now: Date = Date()) {
        switch status {
        case .idle:
            transaction = TransactionState()
        case .active, .failed:
            if transaction.status == .idle {
                transaction = TransactionState(status: status, startedAt: now, statementCount: 1)
            } else {
                transaction.status = status
                transaction.statementCount += 1
            }
        }
    }

    /// Adopt the session's status after something that isn't a user
    /// statement (COMMIT button, batch wrap-up, reconnect) — no count change.
    func syncTransaction(_ status: ScratchpadSession.TransactionStatus, now: Date = Date()) {
        switch status {
        case .idle:
            transaction = TransactionState()
        case .active, .failed:
            if transaction.status == .idle {
                transaction = TransactionState(status: status, startedAt: now, statementCount: 0)
            } else {
                transaction.status = status
            }
        }
    }

    /// Ask before discarding an open transaction (tab or window close).
    /// Returns false when the user chose to keep the tab open. Commit runs on
    /// the session and is waited for; the tab only closes once the server
    /// confirmed it, so a failed COMMIT can never turn into a silent
    /// rollback. Roll Back just closes the session (the server rolls back on
    /// disconnect). With no open transaction this closes the session and
    /// returns true without asking.
    func confirmCloseWithOpenTransaction() -> Bool {
        guard transaction.isOpen, let session else {
            closeSession()
            return true
        }
        let busy = isRunning || runTask != nil
        let failed = transaction.status == .failed
        let alert = NSAlert()
        alert.messageText = "“\(title)” has an open transaction"
        var choices: [String]
        if busy {
            alert.informativeText = "A statement is still running inside the transaction, so it can't be committed yet. Wait for it to finish, or stop it and roll everything back."
            alert.addButton(withTitle: "Stop and Roll Back")
            alert.addButton(withTitle: "Cancel")
            choices = ["rollback", "cancel"]
        } else {
            alert.informativeText = failed
                ? "The transaction has failed and can only be rolled back."
                : "\(transaction.statementCount) statement\(transaction.statementCount == 1 ? "" : "s") since BEGIN. Commit them, or roll everything back?"
            if !failed { alert.addButton(withTitle: "Commit") }
            alert.addButton(withTitle: "Roll Back")
            alert.addButton(withTitle: "Cancel")
            choices = failed ? ["rollback", "cancel"] : ["commit", "rollback", "cancel"]
        }
        let index = alert.runModal().rawValue - NSApplication.ModalResponse.alertFirstButtonReturn.rawValue
        switch choices.indices.contains(index) ? choices[index] : "cancel" {
        case "commit":
            return commitBeforeClose(session)
        case "rollback":
            closeSession()
            return true
        default:
            return false
        }
    }

    /// Outcome of the COMMIT issued from the close prompt.
    enum CloseCommitOutcome: Equatable {
        case committed
        case failed(String)
        case timedOut
    }

    static let closeCommitTimeout: TimeInterval = 20

    /// Pure mapping from what the session reported to the close decision:
    /// a COMMIT that ran on a freshly reopened connection committed nothing
    /// (the old backend rolled back when it died), and a transaction still
    /// open afterwards means the COMMIT didn't end it.
    nonisolated static func closeCommitOutcome(
        reconnected: Bool, statusAfter: ScratchpadSession.TransactionStatus
    ) -> CloseCommitOutcome {
        if reconnected {
            return .failed("The session's connection was lost before COMMIT, so the server already rolled the transaction back.")
        }
        if statusAfter != .idle {
            return .failed("The transaction is still open after COMMIT.")
        }
        return .committed
    }

    private func commitBeforeClose(_ session: ScratchpadSession) -> Bool {
        let outcome: CloseCommitOutcome
        switch Self.waitSynchronously(timeout: Self.closeCommitTimeout, {
            try await session.run("COMMIT", rowLimit: 1)
        }) {
        case .none:
            outcome = .timedOut
        case .some(.success(let response)):
            outcome = Self.closeCommitOutcome(reconnected: response.reconnected, statusAfter: response.transaction)
        case .some(.failure(let error)):
            outcome = .failed(PostgresErrorMessage.describe(error))
        }
        switch outcome {
        case .committed:
            closeSession()
            return true
        case .failed(let message):
            syncTransaction(session.transactionStatus)
            Self.showCloseCommitProblem("COMMIT failed — “\(title)” stays open", message)
            return false
        case .timedOut:
            Self.showCloseCommitProblem(
                "COMMIT hasn't finished — “\(title)” stays open",
                "The server didn't answer within \(Int(Self.closeCommitTimeout)) seconds. Check the transaction indicator once it settles before closing again.")
            return false
        }
    }

    private static func showCloseCommitProblem(_ title: String, _ message: String) {
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = title
        alert.informativeText = message
        alert.addButton(withTitle: "OK")
        alert.runModal()
    }

    /// Runs `operation` off the main actor and blocks the caller by spinning
    /// the main run loop until it finishes. Close and quit confirmations are
    /// synchronous AppKit callbacks (`windowShouldClose`,
    /// `applicationShouldTerminate`), so the COMMIT has to land before they
    /// return. nil = timed out (the operation keeps running).
    static func waitSynchronously<T: Sendable>(
        timeout: TimeInterval,
        _ operation: @escaping @Sendable () async throws -> T
    ) -> Result<T, Error>? {
        let box = ResultBox<T>()
        Task.detached {
            let result: Result<T, Error>
            do { result = .success(try await operation()) } catch { result = .failure(error) }
            box.set(result)
        }
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if let done = box.value { return done }
            RunLoop.current.run(mode: .default, before: Date().addingTimeInterval(0.02))
        }
        return box.value
    }

    /// Per-cell cap on stacked result history. Older results under a cell are
    /// dropped once a new run pushes the count past this.
    static var resultHistoryLimit: Int {
        let stored = UserDefaults.standard.integer(forKey: "notebook.resultHistoryLimit")
        return stored > 0 ? stored : 5
    }

    /// Remove every finished result from the notebook.
    func clearResults() {
        var doomed = Set<UUID>()
        for cell in cells {
            guard case .result(let rid) = cell.kind else { continue }
            if let r = results[rid], case .running = r.status { continue }
            doomed.insert(rid)
        }
        guard !doomed.isEmpty else { return }
        for rid in doomed { results.removeValue(forKey: rid) }
        cells.removeAll { cell in
            if case .result(let rid) = cell.kind { return doomed.contains(rid) }
            return false
        }
        if !cells.contains(where: { $0.kind == .sql }) {
            cells.append(NotebookCell(kind: .sql))
        }
    }

    // MARK: - Cells

    func sqlCell(id: UUID) -> NotebookCell? {
        cells.first(where: { $0.id == id && $0.kind == .sql })
    }

    func insert(_ cell: NotebookCell, after anchorID: UUID) {
        guard let idx = cells.firstIndex(where: { $0.id == anchorID }) else {
            cells.append(cell); return
        }
        cells.insert(cell, at: idx + 1)
    }

    func remove(cellID: UUID) {
        guard let idx = cells.firstIndex(where: { $0.id == cellID }) else { return }
        let cell = cells[idx]
        if case .result(let resultID) = cell.kind {
            results.removeValue(forKey: resultID)
        }
        cells.remove(at: idx)
        // Always keep at least one SQL cell as a typing surface.
        if !cells.contains(where: { $0.kind == .sql }) {
            cells.append(NotebookCell(kind: .sql))
        }
    }

    /// The result cells (and their resultIDs) immediately following
    /// `sqlCellID`, before the next SQL cell. Used by the runner to
    /// decide whether to reuse the existing widgets in place.
    func adjacentResults(after sqlCellID: UUID) -> [(cellIndex: Int, resultID: UUID)] {
        guard let idx = cells.firstIndex(where: { $0.id == sqlCellID }) else { return [] }
        var out: [(Int, UUID)] = []
        var i = idx + 1
        while i < cells.count {
            if case .result(let rid) = cells[i].kind {
                out.append((i, rid))
                i += 1
            } else {
                break
            }
        }
        return out
    }

    /// Walk every SQL cell and concatenate its text. Used by the saved-
    /// queries "Save current scratchpad" button + session restore.
    var plainText: String {
        cells.compactMap { cell in
            cell.kind == .sql ? cell.text : nil
        }.joined(separator: "\n\n")
    }

    // MARK: - Result lifecycle

    func startResult(id: UUID, statement: String) -> NotebookResult {
        if let existing = results[id] {
            existing.statement = statement
            existing.startedAt = Date()
            existing.finishedAt = nil
            existing.status = .running
            // Deliberately NOT touching `isCollapsed` here — the runner
            // owns collapse policy (e.g. multi-statement runs collapse
            // every widget; single-statement reruns preserve whatever the
            // user manually toggled).
            return existing
        }
        let new = NotebookResult(id: id, statement: statement)
        results[id] = new
        return new
    }

    func result(id: UUID) -> NotebookResult? {
        results[id]
    }

    /// Stack a new run's results *after* whatever results already sit under
    /// `sqlCellID`, collapsing the prior ones so the latest run is what you
    /// see. Re-running a cell accumulates a history, capped at
    /// `historyLimit` results per cell (oldest dropped first) so every page
    /// ever fetched doesn't stay in memory.
    func stackResults(after sqlCellID: UUID, newResultIDs: [UUID], historyLimit: Int = Notebook.resultHistoryLimit) {
        guard cells.contains(where: { $0.id == sqlCellID }) else { return }
        let prior = adjacentResults(after: sqlCellID)
        let overflow = prior.count + newResultIDs.count - max(historyLimit, newResultIDs.count)
        if overflow > 0 {
            let doomed = Set(prior.prefix(overflow).map(\.resultID))
            for rid in doomed { results.removeValue(forKey: rid) }
            cells.removeAll { cell in
                if case .result(let rid) = cell.kind { return doomed.contains(rid) }
                return false
            }
        }
        guard let anchorIdx = cells.firstIndex(where: { $0.id == sqlCellID }) else { return }
        let existing = adjacentResults(after: sqlCellID)
        // Collapse every prior result for this cell — "not current ones".
        for entry in existing {
            results[entry.resultID]?.isCollapsed = true
        }
        // Insert the new result cells after the last existing adjacent result
        // (or right after the SQL cell when there were none yet).
        var insertAt = (existing.last?.cellIndex ?? anchorIdx) + 1
        for rid in newResultIDs {
            cells.insert(NotebookCell(kind: .result(resultID: rid)), at: insertAt)
            insertAt += 1
        }
        // Keep a fresh trailing SQL cell so the user can keep typing.
        if insertAt >= cells.count || cells[insertAt].kind != .sql {
            cells.insert(NotebookCell(kind: .sql), at: insertAt)
        }
    }
}

/// One cell in the notebook. SwiftUI uses `id` for ForEach diffing; `kind`
/// switches the rendering. Reference type so SwiftUI can bind to `text`
/// without a value-type churn pattern.
@MainActor
@Observable
final class NotebookCell: Identifiable, Equatable {
    enum Kind: Equatable {
        case sql
        case result(resultID: UUID)
    }
    let id = UUID()
    var kind: Kind
    /// Only meaningful when `kind == .sql`.
    var text: String

    init(kind: Kind, text: String = "") {
        self.kind = kind
        self.text = text
    }

    nonisolated static func == (lhs: NotebookCell, rhs: NotebookCell) -> Bool {
        lhs.id == rhs.id
    }
}

/// One materialised result block. Mirrors what the old attachment-based
/// design had so the existing `DataGridView` rendering carries over.
@MainActor
@Observable
final class NotebookResult: Identifiable {
    enum Status: Sendable {
        case running
        case success(QueryResult)
        case failure(String)
        case cancelled
    }

    let id: UUID
    var statement: String
    var startedAt: Date
    var finishedAt: Date?
    var status: Status
    var isCollapsed: Bool = false

    init(id: UUID = UUID(), statement: String, startedAt: Date = Date(), status: Status = .running) {
        self.id = id
        self.statement = statement
        self.startedAt = startedAt
        self.status = status
    }

    var elapsed: TimeInterval {
        (finishedAt ?? Date()).timeIntervalSince(startedAt)
    }

    var preview: String {
        let collapsed = statement
            .components(separatedBy: .whitespacesAndNewlines)
            .filter { !$0.isEmpty }
            .joined(separator: " ")
        return collapsed.count > 120 ? String(collapsed.prefix(120)) + "…" : collapsed
    }
}

/// Owns the session reference so the notebook's nonisolated `deinit` can
/// close it: closing a tab releases the notebook, and the server connection
/// (with any open transaction) must go with it.
private final class SessionBox: Sendable {
    private let state = Mutex<ScratchpadSession?>(nil)

    var current: ScratchpadSession? { state.withLock { $0 } }

    func replace(with session: ScratchpadSession) {
        let old = state.withLock { s -> ScratchpadSession? in
            defer { s = session }
            return s
        }
        if old !== session { old?.close() }
    }

    func detach() {
        state.withLock { $0 = nil }
    }

    func close() {
        let old = state.withLock { s -> ScratchpadSession? in
            defer { s = nil }
            return s
        }
        old?.close()
    }
}

private final class ResultBox<T: Sendable>: Sendable {
    private let state = Mutex<Result<T, Error>?>(nil)

    var value: Result<T, Error>? { state.withLock { $0 } }

    func set(_ result: Result<T, Error>) {
        state.withLock { $0 = result }
    }
}
