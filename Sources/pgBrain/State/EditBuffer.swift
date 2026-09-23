import Foundation
import Observation

/// Per-grid pending-edit store. Tracks `(rowIndex, columnIndex) → Entry`
/// for cells the user has changed but not yet committed, plus undo / redo
/// stacks so ⌘Z / ⌘⇧Z walk the edit history before Apply.
///
/// An `Entry` is richer than a bare string so the typed-input family can
/// stage not just literals and explicit NULLs but raw SQL expressions
/// (`now()`, `gen_random_uuid()`) and the column `DEFAULT`. The write
/// path (`UpdateApplier`) interprets each kind: literals bind as params,
/// expressions inline as SQL, DEFAULT emits the keyword.
///
/// Row indices are *source* rows of the loaded page. Lives on the
/// `RowsLoader` so it shares the table tab's lifetime.
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

        init(_ typed: TypedInputValue) {
            switch typed {
            case .literal(let s):    self = .literal(s)
            case .null:              self = .literal(nil)
            case .expression(let e): self = .expression(e)
            case .defaultKeyword:    self = .defaultKeyword
            }
        }

        /// The editor-facing form, for re-opening a staged cell in the
        /// right mode.
        var typed: TypedInputValue {
            switch self {
            case .literal(nil):      return .null
            case .literal(let v?):   return .literal(v)
            case .expression(let e): return .expression(e)
            case .defaultKeyword:    return .defaultKeyword
            }
        }

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

    /// A cell's staged state, as recorded by the undo / redo stacks.
    enum CellState: Equatable, Sendable {
        case clean
        case staged(Entry)
    }

    struct Change: Equatable, Sendable {
        let key: CellKey
        let state: CellState
    }

    /// Newest value the user has staged, keyed by cell. Absent key = clean.
    private(set) var edits: [CellKey: Entry] = [:]

    private struct Step {
        var cells: [(key: CellKey, before: CellState, after: CellState)]
    }

    private(set) var undoDepth = 0
    private(set) var redoDepth = 0
    @ObservationIgnored private var undoStack: [Step] = [] { didSet { undoDepth = undoStack.count } }
    @ObservationIgnored private var redoStack: [Step] = [] { didSet { redoDepth = redoStack.count } }
    @ObservationIgnored private var openBatch: Step?
    @ObservationIgnored private var coalescingKey: CellKey?

    /// Fired after every mutation, so the owner can mirror dirtiness onto
    /// state that isn't observing this object (the tab chip, close guards).
    @ObservationIgnored var onChange: (() -> Void)?

    /// Bumps on every mutation — a cheap "something changed" signal for
    /// views that render from the buffer without observing `edits`.
    private(set) var version = 0
    /// Bumps only when staged values change by something other than direct
    /// staging (undo, redo, clear, apply settle-back) — editors keyed on it
    /// re-hydrate then, without losing focus on every keystroke.
    private(set) var externalRevision = 0

    private func changed() {
        version += 1
        onChange?()
    }

    var isDirty: Bool { !edits.isEmpty }
    var dirtyCount: Int { edits.count }
    var canUndo: Bool { undoDepth > 0 }
    var canRedo: Bool { redoDepth > 0 }

    // MARK: - Staging

    func set(row: Int, column: Int, value: String?) {
        apply([Change(key: CellKey(row: row, column: column), state: .staged(.literal(value)))])
    }

    /// `coalesce: true` folds consecutive changes to the same cell into one
    /// undo step — the form view stages on every keystroke, and ⌘Z should
    /// undo the field edit, not one character.
    func set(row: Int, column: Int, typed: TypedInputValue, coalesce: Bool = false) {
        apply([Change(key: CellKey(row: row, column: column), state: .staged(Entry(typed)))], coalesce: coalesce)
    }

    /// Remove a pending edit so the cell returns to its server value.
    func clearCell(row: Int, column: Int, coalesce: Bool = false) {
        let key = CellKey(row: row, column: column)
        guard edits[key] != nil else { return }
        apply([Change(key: key, state: .clean)], coalesce: coalesce)
    }

    /// Stage several cells as one undo step (paste, multi-cell NULL).
    func apply(_ changes: [Change], coalesce: Bool = false) {
        if coalesce, openBatch == nil, changes.count == 1, let change = changes.first,
           coalescingKey == change.key, var last = undoStack.last, last.cells.count == 1,
           last.cells[0].key == change.key {
            let before = edits[change.key].map { CellState.staged($0) } ?? .clean
            guard before != change.state else { return }
            write(change.state, to: change.key)
            last.cells[0].after = change.state
            if last.cells[0].before == change.state {
                undoStack.removeLast()
                coalescingKey = nil
            } else {
                undoStack[undoStack.count - 1] = last
            }
            redoStack.removeAll()
            changed()
            return
        }
        var step = Step(cells: [])
        for change in changes {
            let before: CellState = edits[change.key].map { .staged($0) } ?? .clean
            guard before != change.state else { continue }
            write(change.state, to: change.key)
            step.cells.append((change.key, before, change.state))
        }
        guard !step.cells.isEmpty else { return }
        coalescingKey = (coalesce && step.cells.count == 1) ? step.cells[0].key : nil
        if openBatch != nil {
            openBatch?.cells.append(contentsOf: step.cells)
        } else {
            undoStack.append(step)
            redoStack.removeAll()
            changed()
        }
    }

    /// Group every mutation inside `body` into a single undo step.
    func batch(_ body: () -> Void) {
        guard openBatch == nil else { body(); return }
        openBatch = Step(cells: [])
        body()
        let step = openBatch
        openBatch = nil
        if let step, !step.cells.isEmpty {
            undoStack.append(step)
            redoStack.removeAll()
            changed()
        }
    }

    private func write(_ state: CellState, to key: CellKey) {
        switch state {
        case .clean: edits.removeValue(forKey: key)
        case .staged(let e): edits[key] = e
        }
    }

    // MARK: - Reads

    /// Pending display value: `.none` = clean cell, `.some(nil)` = staged
    /// NULL, `.some(text)` = staged literal/expression/DEFAULT text.
    func value(row: Int, column: Int) -> String?? {
        guard let entry = edits[CellKey(row: row, column: column)] else { return .none }
        return .some(entry.displayValue)
    }

    func entry(row: Int, column: Int) -> Entry? {
        edits[CellKey(row: row, column: column)]
    }

    func isDirty(row: Int, column: Int) -> Bool {
        edits[CellKey(row: row, column: column)] != nil
    }

    /// True when the staged entry is anything other than a plain literal —
    /// the grid uses this to badge expression/DEFAULT cells distinctly.
    func isSpecial(row: Int, column: Int) -> Bool {
        switch edits[CellKey(row: row, column: column)] {
        case .expression, .defaultKeyword: return true
        case .literal, .none: return false
        }
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

    // MARK: - Bulk maintenance

    func clear() {
        externalRevision += 1
        let hadAnything = !edits.isEmpty || !undoStack.isEmpty || !redoStack.isEmpty
        edits.removeAll()
        undoStack.removeAll()
        redoStack.removeAll()
        coalescingKey = nil
        if hadAnything { changed() }
    }

    /// After a successful Apply: drop the entries that were written (still
    /// equal to what was sent) and keep anything staged while the apply was
    /// in flight. History is reset — undoing into already-committed values
    /// would stage phantom edits.
    func settleApplied(_ applied: [CellKey: Entry]) {
        externalRevision += 1
        for (key, entry) in applied where edits[key] == entry {
            edits.removeValue(forKey: key)
        }
        undoStack.removeAll()
        redoStack.removeAll()
        coalescingKey = nil
        changed()
    }

    /// Re-key every staged cell after rows were removed or reordered in the
    /// page. Rows mapped to nil are dropped.
    func remapRows(_ map: (Int) -> Int?) {
        externalRevision += 1
        var next: [CellKey: Entry] = [:]
        for (key, entry) in edits {
            if let r = map(key.row) { next[CellKey(row: r, column: key.column)] = entry }
        }
        edits = next
        func remap(_ steps: [Step]) -> [Step] {
            steps.compactMap { step in
                let cells = step.cells.compactMap { cell -> (key: CellKey, before: CellState, after: CellState)? in
                    guard let r = map(cell.key.row) else { return nil }
                    return (CellKey(row: r, column: cell.key.column), cell.before, cell.after)
                }
                return cells.isEmpty ? nil : Step(cells: cells)
            }
        }
        undoStack = remap(undoStack)
        redoStack = remap(redoStack)
        coalescingKey = nil
        changed()
    }

    // MARK: - Undo / redo

    /// Revert the most recent step. Returns one of the affected cells (the
    /// grid scrolls it into view), nil when there was nothing to undo.
    @discardableResult
    func undo() -> CellKey? {
        externalRevision += 1
        coalescingKey = nil
        guard let step = undoStack.popLast() else { return nil }
        for cell in step.cells.reversed() { write(cell.before, to: cell.key) }
        redoStack.append(step)
        changed()
        return step.cells.first?.key
    }

    @discardableResult
    func redo() -> CellKey? {
        externalRevision += 1
        coalescingKey = nil
        guard let step = redoStack.popLast() else { return nil }
        for cell in step.cells { write(cell.after, to: cell.key) }
        undoStack.append(step)
        changed()
        return step.cells.first?.key
    }
}

extension TypedInputValue {
    /// The editor seed for a server value: NULL stays explicit.
    init(serverValue: String?) {
        self = serverValue.map { .literal($0) } ?? .null
    }
}
