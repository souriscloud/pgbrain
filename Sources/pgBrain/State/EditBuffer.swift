import Foundation
import Observation

/// Per-grid pending-edit store. Tracks `(rowIndex, columnIndex) → Entry`
/// for cells the user has changed but not yet committed, plus a per-edit
/// undo stack so ⌘Z can walk backwards one cell at a time before Apply.
///
/// An `Entry` is richer than a bare string so the typed-input family can
/// stage not just literals and explicit NULLs but raw SQL expressions
/// (`now()`, `gen_random_uuid()`) and the column `DEFAULT`. The write
/// path (`UpdateApplier`) interprets each kind: literals bind as params,
/// expressions inline as SQL, DEFAULT emits the keyword.
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

    /// What the user staged for a cell. `.literal(nil)` is an explicit NULL
    /// (distinct from an absent key = clean cell, and from `.literal("")` =
    /// empty string).
    enum Entry: Equatable, Sendable {
        case literal(String?)
        case expression(String)
        case defaultKeyword

        /// Text shown in the grid/form for this pending value. NULL renders
        /// as `nil` so the cell shows its italic "NULL"; everything else
        /// shows its source text.
        var displayValue: String? {
            switch self {
            case .literal(let v): return v
            case .expression(let e): return e
            case .defaultKeyword: return "DEFAULT"
            }
        }
    }

    /// Newest value the user has staged, keyed by cell. Absent key = clean.
    private(set) var edits: [CellKey: Entry] = [:]

    /// One entry per mutating call, recording the cell's prior state so
    /// `undo()` can restore it.
    @ObservationIgnored private var history: [HistoryEntry] = []

    private struct HistoryEntry {
        let key: CellKey
        let previous: Previous
    }

    private enum Previous {
        case cleanSlate          // no entry before this change
        case dirty(Entry)        // a prior staged entry
    }

    var isDirty: Bool { !edits.isEmpty }
    var dirtyCount: Int { edits.count }
    var canUndo: Bool { !history.isEmpty }

    // MARK: - Staging

    /// Stage a literal value (or explicit NULL). Kept as the primary entry
    /// point so existing call sites that only deal in strings are unchanged.
    func set(row: Int, column: Int, value: String?) {
        stage(row: row, column: column, entry: .literal(value))
    }

    /// Stage a typed value produced by the input family.
    func set(row: Int, column: Int, typed: TypedInputValue) {
        switch typed {
        case .literal(let s):    stage(row: row, column: column, entry: .literal(s))
        case .null:              stage(row: row, column: column, entry: .literal(nil))
        case .expression(let e): stage(row: row, column: column, entry: .expression(e))
        case .defaultKeyword:    stage(row: row, column: column, entry: .defaultKeyword)
        }
    }

    private func stage(row: Int, column: Int, entry: Entry) {
        let key = CellKey(row: row, column: column)
        let previous: Previous = edits[key].map { .dirty($0) } ?? .cleanSlate
        history.append(HistoryEntry(key: key, previous: previous))
        edits[key] = entry
    }

    // MARK: - Reads

    /// Pending display value: `.none` = clean cell, `.some(nil)` = staged
    /// NULL, `.some(text)` = staged literal/expression/DEFAULT text. Keeps
    /// the `String??` contract the grid + form views already consume.
    func value(row: Int, column: Int) -> String?? {
        guard let entry = edits[CellKey(row: row, column: column)] else { return .none }
        return .some(entry.displayValue)
    }

    /// The full staged entry, for the editor (to re-open in the right mode)
    /// and the applier (to choose bind vs. inline).
    func entry(row: Int, column: Int) -> Entry? {
        edits[CellKey(row: row, column: column)]
    }

    func isDirty(row: Int, column: Int) -> Bool {
        edits.keys.contains(CellKey(row: row, column: column))
    }

    /// True when the staged entry is anything other than a plain literal —
    /// the grid uses this to badge expression/DEFAULT cells distinctly.
    func isSpecial(row: Int, column: Int) -> Bool {
        switch edits[CellKey(row: row, column: column)] {
        case .expression, .defaultKeyword: return true
        case .literal, .none: return false
        }
    }

    /// Remove a pending edit so the cell returns to its server value.
    func clearCell(row: Int, column: Int) {
        let key = CellKey(row: row, column: column)
        guard let existing = edits[key] else { return }
        history.append(HistoryEntry(key: key, previous: .dirty(existing)))
        edits.removeValue(forKey: key)
    }

    /// Group all pending edits by row so the applier can emit one statement
    /// per dirty row instead of one per cell.
    func editsByRow() -> [(row: Int, cells: [(column: Int, entry: Entry)])] {
        var byRow: [Int: [(column: Int, entry: Entry)]] = [:]
        for (key, entry) in edits {
            byRow[key.row, default: []].append((column: key.column, entry: entry))
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
        case .dirty(let e):
            edits[last.key] = e
        }
        return last.key
    }
}
