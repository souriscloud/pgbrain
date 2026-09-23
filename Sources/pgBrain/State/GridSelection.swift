import Foundation

/// Spreadsheet-style cell selection over a grid in *display* coordinates
/// (visible row, on-screen column order). One or more rectangles; the last
/// one is active and grows from `anchor` to `cursor`. Pure value type so
/// the selection, copy and paste rules are unit-testable without AppKit.
struct GridSelection: Equatable, Sendable {
    struct Cell: Hashable, Sendable {
        var row: Int
        var col: Int
    }

    struct Rect: Equatable, Sendable {
        var rows: ClosedRange<Int>
        var cols: ClosedRange<Int>

        init(_ a: Cell, _ b: Cell) {
            rows = min(a.row, b.row)...max(a.row, b.row)
            cols = min(a.col, b.col)...max(a.col, b.col)
        }

        func contains(_ c: Cell) -> Bool { rows.contains(c.row) && cols.contains(c.col) }
        var cellCount: Int { rows.count * cols.count }
    }

    private(set) var ranges: [Rect] = []
    private(set) var anchor: Cell?
    private(set) var cursor: Cell?

    var isEmpty: Bool { ranges.isEmpty }

    /// Plain click / arrow: exactly one cell.
    mutating func select(_ cell: Cell) {
        anchor = cell
        cursor = cell
        ranges = [Rect(cell, cell)]
    }

    /// ⇧-click / ⇧-arrow: the active rectangle spans anchor → `cell`.
    mutating func extend(to cell: Cell) {
        guard let anchor else { return select(cell) }
        cursor = cell
        if ranges.isEmpty { ranges = [Rect(anchor, cell)] } else { ranges[ranges.count - 1] = Rect(anchor, cell) }
    }

    /// ⌘-click: start another rectangle, keeping the existing ones — or
    /// carve the cell back out when it's the only cell of a rectangle.
    mutating func add(_ cell: Cell) {
        if let i = ranges.firstIndex(where: { $0 == Rect(cell, cell) }), ranges.count > 1 {
            ranges.remove(at: i)
            cursor = ranges.last.map { Cell(row: $0.rows.upperBound, col: $0.cols.upperBound) }
            anchor = ranges.last.map { Cell(row: $0.rows.lowerBound, col: $0.cols.lowerBound) }
            return
        }
        anchor = cell
        cursor = cell
        ranges.append(Rect(cell, cell))
    }

    mutating func selectAll(rows: Int, cols: Int) {
        guard rows > 0, cols > 0 else { return clear() }
        let first = cursor ?? Cell(row: 0, col: 0)
        ranges = [Rect(Cell(row: 0, col: 0), Cell(row: rows - 1, col: cols - 1))]
        anchor = Cell(row: 0, col: 0)
        cursor = first
    }

    /// Gutter click: whole rows, every column.
    mutating func selectRows(from a: Int, to b: Int, cols: Int, adding: Bool = false) {
        guard cols > 0 else { return }
        let rect = Rect(Cell(row: a, col: 0), Cell(row: b, col: cols - 1))
        if adding { ranges.append(rect) } else { ranges = [rect] }
        anchor = Cell(row: a, col: 0)
        cursor = Cell(row: b, col: cursor?.col ?? 0)
    }

    mutating func clear() {
        ranges = []
        anchor = nil
        cursor = nil
    }

    /// Arrow / Tab navigation. `extend` keeps the anchor (⇧); otherwise the
    /// selection collapses onto the new cursor. `wrap` lets Tab run off the
    /// end of a row onto the next one.
    mutating func move(rowDelta: Int, colDelta: Int, rows: Int, cols: Int, extend: Bool = false, wrap: Bool = false) {
        guard rows > 0, cols > 0 else { return clear() }
        guard let current = cursor else { return select(Cell(row: 0, col: 0)) }
        var r = current.row + rowDelta
        var c = current.col + colDelta
        if wrap {
            if c >= cols, r + 1 < rows { c = 0; r += 1 }
            if c < 0, r > 0 { c = cols - 1; r -= 1 }
        }
        let next = Cell(row: max(0, min(rows - 1, r)), col: max(0, min(cols - 1, c)))
        if extend { self.extend(to: next) } else { select(next) }
    }

    /// Drop anything past the grid's current bounds (after rows vanish).
    mutating func clamp(rows: Int, cols: Int) {
        guard rows > 0, cols > 0 else { return clear() }
        ranges = ranges.compactMap { r in
            guard r.rows.lowerBound < rows, r.cols.lowerBound < cols else { return nil }
            return Rect(Cell(row: r.rows.lowerBound, col: r.cols.lowerBound),
                        Cell(row: min(r.rows.upperBound, rows - 1), col: min(r.cols.upperBound, cols - 1)))
        }
        if ranges.isEmpty { return clear() }
        func fit(_ c: Cell?) -> Cell? { c.map { Cell(row: min($0.row, rows - 1), col: min($0.col, cols - 1)) } }
        anchor = fit(anchor)
        cursor = fit(cursor)
    }

    func contains(_ cell: Cell) -> Bool { ranges.contains { $0.contains(cell) } }

    /// Sorted rows touched by any rectangle.
    var rows: [Int] {
        var set = Set<Int>()
        for r in ranges { set.formUnion(r.rows) }
        return set.sorted()
    }

    var cols: [Int] {
        var set = Set<Int>()
        for r in ranges { set.formUnion(r.cols) }
        return set.sorted()
    }

    /// Every selected cell once, row-major.
    var cells: [Cell] {
        var seen = Set<Cell>()
        var out: [Cell] = []
        for row in rows {
            for col in cols {
                let c = Cell(row: row, col: col)
                if contains(c), seen.insert(c).inserted { out.append(c) }
            }
        }
        return out
    }

    var isSingleCell: Bool { ranges.count == 1 && ranges[0].cellCount == 1 }

    /// Top-left of the union — where a paste lands.
    var origin: Cell? {
        guard !ranges.isEmpty else { return nil }
        return Cell(row: ranges.map(\.rows.lowerBound).min() ?? 0, col: ranges.map(\.cols.lowerBound).min() ?? 0)
    }
}

/// Tab-separated clipboard text for grid ranges, in the spreadsheet dialect
/// Numbers / Excel / Sheets read and write: fields containing a tab, newline
/// or quote are wrapped in quotes with inner quotes doubled.
enum GridClipboard {
    /// User default holding the text NULL copies as (empty by default, so a
    /// spreadsheet sees a blank cell).
    static let nullTokenDefaultsKey = "pgbrain.grid.copyNullAs"

    static var nullToken: String {
        UserDefaults.standard.string(forKey: nullTokenDefaultsKey) ?? ""
    }

    static func encodeField(_ s: String) -> String {
        guard s.contains(where: { $0 == "\t" || $0.isNewline || $0 == "\"" }) else { return s }
        return "\"" + s.replacingOccurrences(of: "\"", with: "\"\"") + "\""
    }

    /// The selection as TSV. Rows / columns are the union of every
    /// rectangle; cells inside that box but outside the selection come out
    /// empty so a multi-range copy keeps its shape.
    static func tsv(
        for selection: GridSelection,
        value: (GridSelection.Cell) -> String?,
        nullToken: String = GridClipboard.nullToken
    ) -> String {
        let rows = selection.rows
        let cols = selection.cols
        return rows.map { row in
            cols.map { col -> String in
                let cell = GridSelection.Cell(row: row, col: col)
                guard selection.contains(cell) else { return "" }
                return encodeField(value(cell) ?? nullToken)
            }
            .joined(separator: "\t")
        }
        .joined(separator: "\n")
    }

    /// Parse clipboard TSV into rows of fields (quoted fields may span tabs
    /// and newlines). A single trailing newline doesn't add an empty row.
    static func parse(_ text: String) -> [[String]] {
        var rows: [[String]] = []
        var row: [String] = []
        var field = ""
        var inQuotes = false
        var atFieldStart = true
        let chars = Array(text)
        var i = 0
        while i < chars.count {
            let c = chars[i]
            if inQuotes {
                if c == "\"" {
                    if i + 1 < chars.count, chars[i + 1] == "\"" { field.append("\""); i += 2; continue }
                    inQuotes = false
                } else {
                    field.append(c)
                }
                i += 1
                continue
            }
            switch c {
            case "\"" where atFieldStart:
                inQuotes = true
                atFieldStart = false
            case "\t":
                row.append(field); field = ""; atFieldStart = true
            case _ where c.isNewline:
                // "\r\n" is a single Character in Swift.
                row.append(field); rows.append(row); row = []; field = ""; atFieldStart = true
            default:
                field.append(c)
                atFieldStart = false
            }
            i += 1
        }
        if !field.isEmpty || !row.isEmpty || inQuotes {
            row.append(field)
            rows.append(row)
        }
        return rows
    }

    struct PastePlan: Equatable {
        var cells: [(cell: GridSelection.Cell, text: String)]
        /// Clipboard fields that fell past the last row / column.
        var clipped: Int

        static func == (a: PastePlan, b: PastePlan) -> Bool {
            a.clipped == b.clipped && a.cells.map(\.cell) == b.cells.map(\.cell) && a.cells.map(\.text) == b.cells.map(\.text)
        }
    }

    /// Where each pasted field lands. A single value fills every selected
    /// cell; a block pastes from the selection's top-left and is clipped at
    /// the grid edge (never grows the page).
    static func plan(
        _ clipboard: [[String]],
        into selection: GridSelection,
        rowCount: Int,
        colCount: Int
    ) -> PastePlan {
        guard let origin = selection.origin, !clipboard.isEmpty else { return PastePlan(cells: [], clipped: 0) }
        if clipboard.count == 1, clipboard[0].count == 1, !selection.isSingleCell {
            let text = clipboard[0][0]
            return PastePlan(cells: selection.cells.map { ($0, text) }, clipped: 0)
        }
        var cells: [(cell: GridSelection.Cell, text: String)] = []
        var clipped = 0
        for (dr, fields) in clipboard.enumerated() {
            for (dc, text) in fields.enumerated() {
                let r = origin.row + dr, c = origin.col + dc
                if r < rowCount, c < colCount {
                    cells.append((GridSelection.Cell(row: r, col: c), text))
                } else {
                    clipped += 1
                }
            }
        }
        return PastePlan(cells: cells, clipped: clipped)
    }
}
