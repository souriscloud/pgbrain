import AppKit
import Foundation
import Observation

/// DataGrip-style SQL console. One editor buffer (`sql`) holds any number of
/// statements; running produces an ordered set of result blocks shown in a
/// panel below the editor. Replaces the earlier cell-stack model (each SQL
/// cell owning its own inline result) — the console is closer to the
/// professional flow pgBrain copies, and lets you run the statement under the
/// caret, a selection, or the whole buffer without managing cells.
@MainActor
@Observable
final class Notebook: Identifiable {
    let id = UUID()
    var title: String
    /// Schema this notebook scopes its queries to. `nil` means "use the
    /// connection's default `search_path`". When non-nil, the runner runs
    /// `SET search_path TO "name"` on the checked-out connection before each
    /// statement and `RESET search_path` afterwards so the pool stays clean.
    var searchPath: String?
    /// The single SQL editor buffer.
    var sql: String = ""
    /// Results of the most recent run, in execution order. Each id keys into
    /// `results`. A new run replaces this set.
    private(set) var resultOrder: [UUID] = []
    /// Result records keyed by UUID. Stored out-of-band so order changes don't
    /// disturb status updates landing on an individual result.
    private(set) var results: [UUID: NotebookResult] = [:]
    /// True while a run is in flight — drives the editor's running rail.
    var isRunning = false
    /// Pulse: SQL string the user wants explained. `NotebookView` catches the
    /// change, opens the EXPLAIN sheet, and clears it.
    var requestedExplainSQL: String?
    /// Pulse: ask the host to open the result-diff sheet on the last two
    /// successful results in this notebook.
    var requestedDiffLastTwo: Bool = false
    /// When true, a multi-statement run is wrapped in a single BEGIN/COMMIT on
    /// one pooled connection so a partial-batch failure rolls back the whole
    /// thing. Default off — keeps the "each statement autocommits" model.
    var runAsTransaction: Bool = false

    init(title: String) {
        self.title = title
    }

    // MARK: - Results

    /// The current run's results, in order, resolved to records.
    var orderedResults: [NotebookResult] {
        resultOrder.compactMap { results[$0] }
    }

    /// Begin a fresh run: install `ids` as the result order and drop any
    /// records from the previous run that aren't being reused.
    func beginRun(resultIDs ids: [UUID]) {
        let keep = Set(ids)
        for key in Array(results.keys) where !keep.contains(key) {
            results.removeValue(forKey: key)
        }
        resultOrder = ids
    }

    func startResult(id: UUID, statement: String) -> NotebookResult {
        if let existing = results[id] {
            existing.statement = statement
            existing.startedAt = Date()
            existing.finishedAt = nil
            existing.status = .running
            return existing
        }
        let new = NotebookResult(id: id, statement: statement)
        results[id] = new
        return new
    }

    func result(id: UUID) -> NotebookResult? {
        results[id]
    }

    func removeResult(id: UUID) {
        results.removeValue(forKey: id)
        resultOrder.removeAll { $0 == id }
    }
}

/// One materialised result block. Reference type so SwiftUI can bind to its
/// mutating status as the async run progresses.
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
