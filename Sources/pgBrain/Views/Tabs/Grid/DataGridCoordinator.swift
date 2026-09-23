import AppKit
import SwiftUI

extension DataGridView {
    @MainActor
    final class Coordinator: NSObject, NSTableViewDataSource, NSTableViewDelegate {
        var page: RowsFetcher.Page
        var editBuffer: EditBuffer?
        var appliedHighlights: Set<EditBuffer.CellKey> = []
        var insertRowIndices: Set<Int> = []
        var deleteRowIndices: Set<Int> = []
        var sourceRowIndices: [Int] = []
        var sortDirectionFor: ((String) -> TypedHeaderCell.SortDirection)?
        var onHeaderClick: ((String, TypedHeaderCell.SortDirection) -> Void)?
        var onCopyRowAsInsert: ((Int) -> Void)?
        var onCopyRowAsDelete: ((Int) -> Void)?
        var onDuplicateRow: ((Int) -> Void)?
        var onFilterEqualsCell: ((Int, Int) -> Void)?
        var onFilterColumn: ((Int, ColumnFilterMode) -> Void)?
        var onCopyAsMarkdown: (() -> Void)?
        var onCopyAsSlack: (() -> Void)?
        var onCommandClickCell: ((Int, Int) -> Void)?
        var onShowColumnDistinct: ((String) -> Void)?
        var makeProfilerController: ((String) -> NSViewController?)?
        /// Retains the live profiler popover so it isn't deallocated while shown.
        var profilerPopover: NSPopover?
        var onDeleteRows: (([Int]) -> Void)?
        var columnLayoutKey: (UUID, String, String)?

        @objc func columnDidResize(_ notification: Notification) {
            guard let col = notification.userInfo?["NSTableColumn"] as? NSTableColumn,
                  let key = columnLayoutKey
            else { return }
            let id = col.identifier.rawValue
            // Skip the gutter column.
            if id == Self.gutterColumnID { return }
            // Identifier is `<index>_<name>`; strip the prefix.
            guard let underscore = id.firstIndex(of: "_") else { return }
            let name = String(id[id.index(after: underscore)...])
            ColumnLayoutStore.shared.setWidth(
                col.width,
                connectionID: key.0, schema: key.1, table: key.2,
                column: name
            )
        }

        /// Keyboard-focused cell (visible-row index + data-column index,
        /// where data-column-index excludes the row-gutter column 0).
        /// The grid draws a violet ring around this cell and arrow keys
        /// move it.
        var focusedRow: Int? = nil
        var focusedDataCol: Int? = nil

        weak var tableView: NSTableView?
        @ObservationIgnored var observationTask: Task<Void, Never>?

        /// Render cache for the type-aware cell formatter. Building
        /// the attributed string + paragraph style on every cell
        /// recycle was the dominant per-frame cost during fast scroll.
        /// Keyed by `(sourceRow << 16) | dataCol` so a 200×10 grid
        /// caches 2000 entries (~MB). Cleared on page swap + on per-
        /// cell edit commits.
        @ObservationIgnored private var renderCache: [Int: CellFormat.Rendered] = [:]

        var enums: [String: [String]] = [:]
        var schema: SchemaSnapshot = .empty

        init(page: RowsFetcher.Page, editBuffer: EditBuffer?) {
            self.page = page
            self.editBuffer = editBuffer
        }

        /// Called by `updateNSView` when the page identity flips so
        /// we don't serve stale rendered cells for a brand-new
        /// result set.
        func invalidateRenderCache() {
            renderCache.removeAll(keepingCapacity: true)
        }

        /// Live editor-font zoom: drop cached renders, re-height rows, redraw.
        @objc func editorFontDidChange() {
            invalidateRenderCache()
            if let t = tableView {
                t.rowHeight = DataGridView.gridRowHeight()
                t.reloadData()
            }
        }

        /// Per-cell invalidation — fires from the commit path so the
        /// next viewFor call re-renders this cell with its pending
        /// value instead of returning the cached pre-edit string.
        func invalidateRenderCacheCell(sourceRow: Int, dataCol: Int) {
            renderCache.removeValue(forKey: renderKey(sourceRow: sourceRow, col: dataCol))
        }

        func renderKey(sourceRow: Int, col: Int) -> Int {
            (sourceRow << 16) | (col & 0xFFFF)
        }

        func cachedRender(sourceRow: Int, col: Int, value: String?, column: ColumnNode) -> CellFormat.Rendered {
            let key = renderKey(sourceRow: sourceRow, col: col)
            if let hit = renderCache[key] { return hit }
            let r = CellFormat.render(value: value, column: column)
            renderCache[key] = r
            return r
        }

        /// Identifier of the synthetic leftmost row-number column. The
        /// data columns use stable keyed identifiers; this one is special
        /// and gets a dedicated cell view.
        static let gutterColumnID = "__pgbrain_row_index__"

        // Map column identifier → index for O(1) row lookup.
        private var indexByID: [String: Int] = [:]

        func rebuildIndex() {
            indexByID.removeAll(keepingCapacity: true)
            for (i, c) in page.columns.enumerated() {
                indexByID["\(i)_\(c.name)"] = i
            }
        }

        func numberOfRows(in tableView: NSTableView) -> Int { page.rows.count }

        /// Source-row index for a visible row, falling back to identity
        /// when no filter is active so callers can always read this.
        func sourceIndex(forVisibleRow row: Int) -> Int {
            if row >= 0, row < sourceRowIndices.count { return sourceRowIndices[row] }
            return row
        }

        func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
            let columnID = tableColumn?.identifier.rawValue ?? ""
            if columnID == Self.gutterColumnID {
                let cell = reuseGutterCell(in: tableView)
                cell.configure(
                    rowNumber: sourceIndex(forVisibleRow: row) + 1,
                    isFocused: focusedRow == row,
                    isInsert: insertRowIndices.contains(sourceIndex(forVisibleRow: row))
                )
                return cell
            }
            guard let colIdx = indexByID[columnID] else { return nil }
            let column = page.columns[colIdx]
            let sourceRow = sourceIndex(forVisibleRow: row)
            let original = page.rows[row][colIdx]
            let cell = reuseCell(in: tableView)
            let isApplied = appliedHighlights.contains(EditBuffer.CellKey(row: sourceRow, column: colIdx))
            let isFocused = focusedRow == row && focusedDataCol == colIdx
            let value = effectiveValue(sourceRow: sourceRow, col: colIdx, original: original)
            let rendered = cachedRender(sourceRow: sourceRow, col: colIdx, value: value, column: column)
            cell.configure(
                rendered: rendered,
                isDirty: editBuffer?.isDirty(row: sourceRow, column: colIdx) ?? false,
                isRecentlyApplied: isApplied,
                isFocused: isFocused,
                isNull: value == nil
            )
            cell.onCommit = nil
            return cell
        }

        func tableView(_ tableView: NSTableView, heightOfRow row: Int) -> CGFloat { 24 }

        func tableView(_ tableView: NSTableView, rowViewForRow row: Int) -> NSTableRowView? {
            let id = NSUserInterfaceItemIdentifier("HoverRow")
            let src = sourceIndex(forVisibleRow: row)
            let isInsert = insertRowIndices.contains(src)
            let isDelete = deleteRowIndices.contains(src)
            if let v = tableView.makeView(withIdentifier: id, owner: self) as? HoverableRowView {
                v.isInsertRow = isInsert
                v.isDeleteRow = isDelete
                return v
            }
            let v = HoverableRowView()
            v.identifier = id
            v.isInsertRow = isInsert
            v.isDeleteRow = isDelete
            return v
        }

        // MARK: - Sort header clicks

        func tableView(_ tableView: NSTableView, didClick tableColumn: NSTableColumn) {
            guard let onHeaderClick else { return }
            let id = tableColumn.identifier.rawValue
            if id == Self.gutterColumnID { return }
            guard let colIdx = indexByID[id] else { return }
            let name = page.columns[colIdx].name
            // Cycle: unsorted → asc → desc → unsorted, derived from the
            // current direction the parent reports for this column.
            let current = sortDirectionFor?(name) ?? .none
            let next: TypedHeaderCell.SortDirection
            switch current {
            case .none:       next = .ascending
            case .ascending:  next = .descending
            case .descending: next = .none
            }
            onHeaderClick(name, next)
        }

        // MARK: - Cell focus / keyboard nav

        func moveFocus(rowDelta: Int, colDelta: Int) {
            guard let table = tableView, page.rows.count > 0 else { return }
            let rowCount = page.rows.count
            let colCount = page.columns.count
            // First press lands on (0, 0) if nothing is focused yet.
            var r = focusedRow ?? -1
            var c = focusedDataCol ?? -1
            if r < 0 || c < 0 { r = 0; c = 0 } else { r += rowDelta; c += colDelta }
            r = max(0, min(rowCount - 1, r))
            c = max(0, min(colCount - 1, c))
            setFocus(row: r, col: c, in: table)
        }

        func setFocus(row: Int, col: Int, in table: NSTableView) {
            let oldRow = focusedRow
            let oldCol = focusedDataCol
            focusedRow = row
            focusedDataCol = col
            // Repaint the previously- and newly-focused rows so the ring
            // moves cleanly. Repainting the gutter is part of this too —
            // the gutter row number gets a tint when its row is focused.
            var dirty: IndexSet = IndexSet()
            if let or = oldRow { dirty.insert(or) }
            dirty.insert(row)
            let allCols = IndexSet(integersIn: 0..<table.numberOfColumns)
            table.reloadData(forRowIndexes: dirty, columnIndexes: allCols)
            // Scroll into view (data column index +1 to account for gutter).
            table.scrollRowToVisible(row)
            if col + 1 < table.numberOfColumns { table.scrollColumnToVisible(col + 1) }
            _ = oldCol
        }

        func openEditorForFocus() {
            guard let buffer = editBuffer, let table = tableView,
                  let row = focusedRow, let col = focusedDataCol
            else { return }
            presentEditor(row: sourceIndex(forVisibleRow: row), col: col, in: table, buffer: buffer)
        }

        /// ⌃⌘N — stage an explicit NULL for the keyboard-focused cell.
        /// Distinct from clearing a cell to empty text (which stages the
        /// literal ""); this routes through `.null` so the cell renders the
        /// italic "NULL". No-op when the focused column isn't nullable.
        func setNullForFocusedCell() {
            guard editBuffer != nil, let row = focusedRow, let col = focusedDataCol,
                  col >= 0, col < page.columns.count, page.columns[col].nullable
            else { return }
            let sourceRow = sourceIndex(forVisibleRow: row)
            let original = page.rows[row][col]
            commit(row: sourceRow, col: col, original: original, typed: .null)
        }

        /// Full-value content for the hover preview popover, or nil when the
        /// cell isn't worth previewing (short, NULL, or a non-text/json kind).
        /// JSON is pretty-printed; long text is shown verbatim.
        func hoverPreview(forVisibleRow visibleRow: Int, dataCol: Int) -> String? {
            guard visibleRow >= 0, visibleRow < page.rows.count,
                  dataCol >= 0, dataCol < page.columns.count
            else { return nil }
            let column = page.columns[dataCol]
            let sourceRow = sourceIndex(forVisibleRow: visibleRow)
            let original = page.rows[visibleRow][dataCol]
            guard let value = effectiveValue(sourceRow: sourceRow, col: dataCol, original: original)
            else { return nil }
            let kind = ColumnTypeKind.from(typeName: column.typeName)
            switch kind {
            case .json:
                return JSONFormatter.pretty(value) ?? value
            case .text, .unknown:
                // Only worth a popover when the value is long or wraps.
                guard value.count > 60 || value.contains("\n") else { return nil }
                return value
            default:
                return nil
            }
        }

        /// Serialise the current row selection (or the focused cell's row
        /// if no selection) as TSV — values tab-separated, rows
        /// newline-separated, NULL rendered as the empty string. Used by
        /// ⌘C on the table view.
        func copyAsTSV() -> String? {
            guard let table = tableView else { return nil }
            let selected = table.selectedRowIndexes
            let rows: [Int] = selected.isEmpty
                ? (focusedRow.map { [$0] } ?? [])
                : Array(selected)
            guard !rows.isEmpty else { return nil }
            var out: [String] = []
            for vis in rows {
                guard vis >= 0, vis < page.rows.count else { continue }
                let cells = page.rows[vis].map { $0?.replacingOccurrences(of: "\t", with: " ").replacingOccurrences(of: "\n", with: " ") ?? "" }
                out.append(cells.joined(separator: "\t"))
            }
            return out.joined(separator: "\n")
        }

        @objc func handleDoubleClick(_ sender: Any?) {
            guard let buffer = editBuffer, let table = tableView else { return }
            let row = table.clickedRow
            let clickedCol = table.clickedColumn
            guard row >= 0, clickedCol >= 0 else { return }
            // Clicked-column is in *table column space* (gutter is 0);
            // translate to data column.
            let dataCol = clickedCol - 1
            guard dataCol >= 0, dataCol < page.columns.count else { return }
            presentEditor(row: sourceIndex(forVisibleRow: row), col: dataCol, in: table, buffer: buffer)
        }

        /// Show the type-aware popover editor over the clicked cell. Replaces
        /// the old inline NSTextField edit — every type now gets its proper
        /// widget (DatePicker for dates, segmented for bools, monospaced
        /// multiline for JSON…) plus a "Set NULL" button when the column is
        /// nullable.
        func presentEditor(row: Int, col: Int, in table: NSTableView, buffer: EditBuffer) {
            guard col < page.columns.count, row < page.rows.count else { return }
            let column = page.columns[col]
            let original = page.rows[row][col]
            // Seed the editor from any staged entry, else the server value
            // (NULL → NULL mode so the cell's null-ness is explicit).
            let initial: TypedInputValue
            if let entry = buffer.entry(row: row, column: col) {
                switch entry {
                case .literal(nil):      initial = .null
                case .literal(let v?):   initial = .literal(v)
                case .expression(let e): initial = .expression(e)
                case .defaultKeyword:    initial = .defaultKeyword
                }
            } else {
                initial = original == nil ? .null : .literal(original!)
            }
            let rect = table.frameOfCell(atColumn: col, row: row)
            // Expression-mode completion biased toward this table's columns.
            let cols = page.columns
            let schema = self.schema
            let completions: (String, String, Int) -> [CompletionItem] = { partial, _, _ in
                SQLCompletionProvider.items(
                    for: partial, in: schema,
                    context: .expression(columns: cols))
            }
            CellEditorPopover.show(
                for: column,
                initial: initial,
                enums: enums,
                completions: completions,
                relativeTo: rect,
                of: table
            ) { [weak self] typed in
                self?.commit(row: row, col: col, original: original, typed: typed)
            }
        }


        /// When the buffer has a pending edit for the source row, show it
        /// (which may be `nil` for an explicit Set NULL). Otherwise fall
        /// back to the server value.
        private func effectiveValue(sourceRow: Int, col: Int, original: String?) -> String? {
            guard let buffer = editBuffer else { return original }
            if case .some(let pending) = buffer.value(row: sourceRow, column: col) {
                return pending
            }
            return original
        }

        /// Commit a new cell value into the edit buffer. `newValue == nil`
        /// represents an explicit "Set NULL" — distinguishes that case
        /// from an empty string (which is a legitimate non-NULL value).
        /// If the new value equals the server's original, the pending
        /// edit is reverted so the dirty count stays honest.
        func commit(row: Int, col: Int, original: String?, typed: TypedInputValue) {
            guard let buffer = editBuffer else { return }
            // No-op against the original: drop the pending entry so the
            // cell goes back to clean instead of carrying a fake-dirty
            // marker that points at the same value.
            if typed.isNoOp(against: original) {
                if buffer.isDirty(row: row, column: col) {
                    buffer.clearCell(row: row, column: col)
                    invalidateRenderCacheCell(sourceRow: row, dataCol: col)
                    reloadRow(row)
                }
                return
            }
            buffer.set(row: row, column: col, typed: typed)
            invalidateRenderCacheCell(sourceRow: row, dataCol: col)
            // SwiftUI's @Observable chain will eventually re-render the
            // table, but on same-key re-edits the observable signals can
            // coalesce and the cell is left displaying its previous text
            // for a beat. Force the affected row to refresh now so the
            // pending value (and dirty rail) are visible the instant the
            // popover closes — before any Apply.
            reloadRow(row)
        }

        private func reloadRow(_ sourceRow: Int) {
            guard let table = tableView else { return }
            // Find the visible row that maps to this source row.
            let visibleRow: Int = {
                if sourceRowIndices.isEmpty { return sourceRow }
                return sourceRowIndices.firstIndex(of: sourceRow) ?? sourceRow
            }()
            guard visibleRow >= 0, visibleRow < table.numberOfRows else { return }
            let cols = IndexSet(integersIn: 0..<table.numberOfColumns)
            table.reloadData(forRowIndexes: IndexSet(integer: visibleRow), columnIndexes: cols)
        }

        private func reuseCell(in tableView: NSTableView) -> DataCellView {
            let id = NSUserInterfaceItemIdentifier("DataCell")
            if let reused = tableView.makeView(withIdentifier: id, owner: self) as? DataCellView {
                return reused
            }
            let v = DataCellView()
            v.identifier = id
            return v
        }

        private func reuseGutterCell(in tableView: NSTableView) -> RowNumberCellView {
            let id = NSUserInterfaceItemIdentifier("RowNumberCell")
            if let reused = tableView.makeView(withIdentifier: id, owner: self) as? RowNumberCellView {
                return reused
            }
            let v = RowNumberCellView()
            v.identifier = id
            return v
        }
    }
}
