import AppKit
import Foundation
import Observation

/// Notebook-style scratchpad replacement. Replaces the iter-4 stack-of-results
/// model with a single flowing document: SQL text and result widgets live
/// inline in the same `NSTextStorage`. Running a statement inserts (or
/// replaces) an inline `ResultAttachment` right after the run target.
///
/// Result data is stored out-of-band keyed by attachment UUID so the
/// `NSTextStorage` only has to carry a single attachment character per result.
/// That keeps copy/paste, undo, and selection behaviour native — TextKit
/// doesn't see them as anything special.
@MainActor
@Observable
final class Notebook: Identifiable {
    let id = UUID()
    var title: String

    /// The live document. Owned here so multiple SwiftUI bindings (text view,
    /// saved-queries sheet, session restore) all see the same buffer.
    /// `@ObservationIgnored` because mutations come from `NSTextView`'s own
    /// edit cycle — we don't want every keystroke to trigger SwiftUI body
    /// re-evaluation.
    @ObservationIgnored let textStorage: NSTextStorage = NSTextStorage()

    /// Inline-result records keyed by attachment UUID. The attachment carries
    /// the UUID; everything else lives here so attachment views can re-render
    /// when status flips.
    private(set) var results: [UUID: NotebookResult] = [:]

    /// Character range of the SQL that's currently running. Used by the
    /// text view to paint a green JetBrains-style outline around the
    /// in-flight statement(s).
    var runningRange: NSRange?

    init(title: String) {
        self.title = title
    }

    // MARK: - Result lifecycle

    /// Insert or update the result for `id`. Triggers observation so any
    /// attached view picks up the new state.
    func upsert(_ result: NotebookResult) {
        results[result.id] = result
    }

    /// Start (or restart) the result associated with an attachment ID. If
    /// an existing entry is present (replace-in-place case), its in-flight
    /// metadata is reset; otherwise a fresh entry is created. Returning the
    /// instance lets the caller mutate `status`/`finishedAt` as the query
    /// progresses.
    func startResult(id: UUID, statement: String) -> NotebookResult {
        if let existing = results[id] {
            existing.statement = statement
            existing.startedAt = Date()
            existing.finishedAt = nil
            existing.status = .running
            existing.isCollapsed = false
            return existing
        }
        let new = NotebookResult(id: id, statement: statement)
        results[id] = new
        return new
    }

    func remove(id: UUID) {
        results.removeValue(forKey: id)
    }

    func result(id: UUID) -> NotebookResult? {
        results[id]
    }

    /// Plain-text view of the document — used by `SavedQueriesView` and
    /// session restore. Attachments become a single object-replacement
    /// character which is fine for both consumers.
    var plainText: String {
        textStorage.string
    }
}

/// One materialised result block. Mirrors the legacy `ResultBlock` shape so
/// the existing `DataGridView` rendering carries over.
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
    var statement: String   // mutable so replace-in-place keeps fresh SQL
    var startedAt: Date     // reset when the same widget is rerun
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

    /// One-line preview of the originating SQL for the result header.
    var preview: String {
        let collapsed = statement
            .components(separatedBy: .whitespacesAndNewlines)
            .filter { !$0.isEmpty }
            .joined(separator: " ")
        return collapsed.count > 120 ? String(collapsed.prefix(120)) + "…" : collapsed
    }
}
