import AppKit
import Foundation
import Observation

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
    /// When non-nil, the runner runs `SET search_path TO "name"` on the
    /// checked-out connection before each statement and `RESET search_path`
    /// afterwards so the connection pool stays clean.
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

    init(title: String) {
        self.title = title
        // Seed with one empty SQL cell so the user can immediately type.
        self.cells = [NotebookCell(kind: .sql)]
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

    /// Replace the result cells adjacent to `sqlCellID` with `newResultIDs`.
    /// Reuses cells in place for the prefix that overlaps; trims extras;
    /// appends new ones if the new run produced more results than there
    /// were widgets before. Returns nothing — caller already created the
    /// `NotebookResult`s and inserted them in `results`.
    func replaceAdjacentResults(after sqlCellID: UUID, with newResultIDs: [UUID]) {
        guard let anchorIdx = cells.firstIndex(where: { $0.id == sqlCellID }) else { return }
        let existing = adjacentResults(after: sqlCellID)

        // Reuse in place for as many as overlap.
        let overlap = min(existing.count, newResultIDs.count)
        for i in 0..<overlap {
            cells[existing[i].cellIndex].kind = .result(resultID: newResultIDs[i])
            // Drop the old result record from `results` if it differs and
            // is now orphaned.
            if existing[i].resultID != newResultIDs[i] {
                results.removeValue(forKey: existing[i].resultID)
            }
        }

        if existing.count > newResultIDs.count {
            // Trim extras.
            let extras = existing.suffix(existing.count - newResultIDs.count)
            for entry in extras.reversed() {
                results.removeValue(forKey: entry.resultID)
                cells.remove(at: entry.cellIndex)
            }
        } else if newResultIDs.count > existing.count {
            // Append new result cells after the last one we reused (or
            // after the SQL cell if there were none).
            var insertAt = (existing.last?.cellIndex ?? anchorIdx) + 1
            for i in overlap..<newResultIDs.count {
                cells.insert(NotebookCell(kind: .result(resultID: newResultIDs[i])), at: insertAt)
                insertAt += 1
            }
        }

        // Always leave a fresh empty SQL cell after the results so the
        // user can keep typing without manually adding one.
        let afterResults = (existing.last?.cellIndex ?? anchorIdx) + (newResultIDs.count - existing.count) + (existing.isEmpty ? newResultIDs.count : 0)
        let trailingSqlIdx = anchorIdx + 1 + newResultIDs.count
        if trailingSqlIdx >= cells.count || cells[trailingSqlIdx].kind != .sql {
            cells.insert(NotebookCell(kind: .sql), at: trailingSqlIdx)
        }
        _ = afterResults  // satisfy unused
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
