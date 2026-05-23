import Foundation
import Observation

/// Per-grid pending-edit store. Tracks `(rowIndex, columnIndex) → newValue`
/// for cells the user has changed but not yet committed, plus a per-edit
/// undo stack so ⌘Z can walk backwards one cell at a time before Apply.
///
/// Lives on the `RowsLoader` so it shares the table tab's lifetime — closing
/// the tab discards the buffer along with the loader.
@MainActor
@Observable
final class EditBuffer {
    struct CellKey: Hashable, Sendable {
        let row: Int
        let column: Int
    }

    /// Newest value the user has typed, keyed by cell. Absent key = clean cell.
    private(set) var edits: [CellKey: String?] = [:]

    /// One entry per `set(...)` call, recording the value the cell had before
    /// the edit (or `.cleanSlate` if the cell wasn't dirty yet). `undo()` pops
    /// the top entry and restores.
    @ObservationIgnored private var history: [HistoryEntry] = []

    private struct HistoryEntry {
        let key: CellKey
        let previous: Previous
    }

    private enum Previous {
        case cleanSlate                  // no entry in `edits` before this set
        case dirty(value: String?)       // there was a prior dirty value
    }

    var isDirty: Bool { !edits.isEmpty }
    var dirtyCount: Int { edits.count }
    var canUndo: Bool { !history.isEmpty }

    func set(row: Int, column: Int, value: String?) {
        let key = CellKey(row: row, column: column)
        let previous: Previous = edits.keys.contains(key)
            ? .dirty(value: edits[key] ?? nil)
            : .cleanSlate
        history.append(HistoryEntry(key: key, previous: previous))
        edits[key] = value
    }

    func value(row: Int, column: Int) -> String?? {
        let key = CellKey(row: row, column: column)
        return edits.keys.contains(key) ? .some(edits[key] ?? nil) : .none
    }

    func isDirty(row: Int, column: Int) -> Bool {
        edits.keys.contains(CellKey(row: row, column: column))
    }

    /// Group all pending edits by row so the applier can emit one UPDATE per
    /// dirty row instead of one per cell.
    func editsByRow() -> [(row: Int, cells: [(column: Int, value: String?)])] {
        var byRow: [Int: [(column: Int, value: String?)]] = [:]
        for (key, value) in edits {
            byRow[key.row, default: []].append((column: key.column, value: value))
        }
        return byRow
            .map { (row: $0.key, cells: $0.value.sorted { $0.column < $1.column }) }
            .sorted { $0.row < $1.row }
    }

    func clear() {
        edits.removeAll()
        history.removeAll()
    }

    @discardableResult
    func undo() -> CellKey? {
        guard let last = history.popLast() else { return nil }
        switch last.previous {
        case .cleanSlate:
            edits.removeValue(forKey: last.key)
        case .dirty(let v):
            edits[last.key] = v
        }
        return last.key
    }
}
