import AppKit
import SwiftUI

/// `NSTableView` driven by a `RowsFetcher.Page`. Type-aware cells with
/// alignment per column kind, monospaced for numeric/uuid/json/bytes,
/// distinct NULL rendering ("NULL" italic + dimmed) and single-line JSON.
///
/// Editing (iter-5): when `editBuffer` is non-nil and the table has a primary
/// key, columns become editable. Double-clicking a cell opens an inline
/// `NSTextField`; commit on Enter/Tab/focus-loss, Esc reverts. Dirty cells
/// get a tinted background and a yellow corner triangle.
/// Quick-filter modes wired into the grid's cell context menu.
/// Receivers compose the corresponding `col IS NULL` / `col IS NOT
/// NULL` fragment and AND it onto the existing WHERE clause.
enum ColumnFilterMode {
    case isNull, isNotNull
}

struct DataGridView: NSViewRepresentable {
    let page: RowsFetcher.Page
    /// Pass nil to render the grid read-only (e.g. for SQL scratchpad
    /// result blocks). Pass an `EditBuffer` to enable cell editing.
    var editBuffer: EditBuffer? = nil
    /// `(row, column)` cells that were just successfully applied. Cell
    /// rendering paints them with a fading green tint for a few seconds
    /// so the user can see exactly what landed.
    var appliedHighlights: Set<EditBuffer.CellKey> = []
    /// Maps each visible grid row index back to its index in the
    /// unfiltered loaded page — so edits + applies still target the
    /// correct underlying row when a filter is active. Identity map
    /// `[0,1,2…]` when no filter is applied.
    var sourceRowIndices: [Int] = []
    /// Returns the desired arrow indicator for a header column based on
    /// the parent's active `ORDER BY` clause. Passed as a function
    /// (rather than a precomputed dict) so the parent can derive it
    /// however it wants — a parser, a regex, or a per-column lookup.
    var sortDirectionFor: ((String) -> TypedHeaderCell.SortDirection)? = nil
    /// Header click handler — receives the column name and the next
    /// desired direction (cycle is owned by the coordinator).
    var onHeaderClick: ((String, TypedHeaderCell.SortDirection) -> Void)? = nil
    /// Row-level actions surfaced via the right-click menu. Receivers
    /// produce SQL into the user's clipboard.
    var onCopyRowAsInsert: ((Int) -> Void)? = nil
    var onCopyRowAsDelete: ((Int) -> Void)? = nil
    var onDuplicateRow: ((Int) -> Void)? = nil
    /// "Filter to this value" actions — write a `colname = value`
    /// fragment into the parent's WHERE strip and reload.
    var onFilterEqualsCell: ((Int /*sourceRow*/, Int /*dataCol*/) -> Void)? = nil
    var onFilterColumn: ((Int /*dataCol*/, ColumnFilterMode) -> Void)? = nil
    /// Selection-export actions. Receivers serialize the current row
    /// selection in the chosen format and put it on the pasteboard.
    var onCopyAsMarkdown: (() -> Void)? = nil
    var onCopyAsSlack: (() -> Void)? = nil
    /// ⌘-click navigation. Receiver checks whether the cell is on
    /// an FK column and opens the parent table if so.
    var onCommandClickCell: ((Int /*sourceRow*/, Int /*dataCol*/) -> Void)? = nil
    /// `(connectionID, schema, table)` for the column-layout store
    /// keying. Nil disables persisted widths (e.g. for scratchpad
    /// result grids that don't have a stable table identity).
    var columnLayoutKey: (UUID, String, String)? = nil

    @MainActor
    final class Coordinator: NSObject, NSTableViewDataSource, NSTableViewDelegate {
        var page: RowsFetcher.Page
        var editBuffer: EditBuffer?
        var appliedHighlights: Set<EditBuffer.CellKey> = []
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
                    isFocused: focusedRow == row
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
            if let v = tableView.makeView(withIdentifier: id, owner: self) as? HoverableRowView {
                return v
            }
            let v = HoverableRowView()
            v.identifier = id
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
            let displayed: String? = buffer.value(row: row, column: col).flatMap { $0 } ?? original
            let rect = table.frameOfCell(atColumn: col, row: row)
            CellEditorPopover.show(
                for: column,
                currentValue: displayed,
                relativeTo: rect,
                of: table
            ) { [weak self] newValue in
                self?.commit(row: row, col: col, original: original, newValue: newValue)
            }
        }

        /// Builds the right-click context menu for the cell under the
        /// pointer. `visibleRow` is the index in the (possibly filtered)
        /// view; `dataCol` is the index in `page.columns`. We translate
        /// `visibleRow` to its source-row immediately so subsequent
        /// actions target the underlying data row.
        func contextMenu(forVisibleRow visibleRow: Int, dataCol: Int) -> NSMenu? {
            guard visibleRow >= 0, dataCol >= 0, dataCol < page.columns.count, visibleRow < page.rows.count else { return nil }
            let sourceRow = sourceIndex(forVisibleRow: visibleRow)
            let column = page.columns[dataCol]
            let original = page.rows[visibleRow][dataCol]
            let displayed: String? = editBuffer?.value(row: sourceRow, column: dataCol).flatMap { $0 } ?? original

            let menu = NSMenu()
            let copy = NSMenuItem(title: "Copy value", action: #selector(handleCopy(_:)), keyEquivalent: "")
            copy.target = self
            copy.representedObject = displayed ?? ""
            menu.addItem(copy)

            let copyName = NSMenuItem(title: "Copy column name", action: #selector(handleCopy(_:)), keyEquivalent: "")
            copyName.target = self
            copyName.representedObject = column.name
            menu.addItem(copyName)

            // Filter-to-value bloc. Available regardless of edit
            // buffer — these write to the WHERE strip, no PK needed.
            if onFilterEqualsCell != nil || onFilterColumn != nil {
                menu.addItem(.separator())
                if onFilterEqualsCell != nil {
                    let label: String = {
                        guard let displayed else {
                            return "Filter to NULL on \(column.name)"
                        }
                        let preview = displayed.count > 24
                            ? String(displayed.prefix(22)) + "…"
                            : displayed
                        return "Filter to \"\(preview)\""
                    }()
                    let item = NSMenuItem(title: label, action: #selector(handleFilterToCell(_:)), keyEquivalent: "")
                    item.target = self
                    item.representedObject = CellLocator(row: sourceRow, col: dataCol)
                    menu.addItem(item)
                }
                if onFilterColumn != nil {
                    let nullItem = NSMenuItem(title: "Filter: \(column.name) IS NULL", action: #selector(handleFilterIsNull(_:)), keyEquivalent: "")
                    nullItem.target = self
                    nullItem.representedObject = dataCol
                    menu.addItem(nullItem)
                    let notNullItem = NSMenuItem(title: "Filter: \(column.name) IS NOT NULL", action: #selector(handleFilterIsNotNull(_:)), keyEquivalent: "")
                    notNullItem.target = self
                    notNullItem.representedObject = dataCol
                    menu.addItem(notNullItem)
                }
            }

            // Selection-export bloc. Only meaningful when at least one
            // row is selected (or focused) — the receivers gate the
            // pasteboard write themselves but no point cluttering
            // the menu otherwise.
            if onCopyAsMarkdown != nil || onCopyAsSlack != nil {
                menu.addItem(.separator())
                if onCopyAsMarkdown != nil {
                    let item = NSMenuItem(title: "Copy selection as Markdown table", action: #selector(handleCopyMarkdown(_:)), keyEquivalent: "")
                    item.target = self
                    menu.addItem(item)
                }
                if onCopyAsSlack != nil {
                    let item = NSMenuItem(title: "Copy selection as Slack code block", action: #selector(handleCopySlack(_:)), keyEquivalent: "")
                    item.target = self
                    menu.addItem(item)
                }
            }

            // Row-level actions live on the same menu when the grid has
            // a primary key + edit buffer (i.e. this is a real table).
            if editBuffer != nil {
                menu.addItem(.separator())
                let asInsert = NSMenuItem(title: "Copy row as INSERT", action: #selector(handleRowInsert(_:)), keyEquivalent: "")
                asInsert.target = self
                asInsert.representedObject = sourceRow
                menu.addItem(asInsert)
                let asDelete = NSMenuItem(title: "Copy row as DELETE", action: #selector(handleRowDelete(_:)), keyEquivalent: "")
                asDelete.target = self
                asDelete.representedObject = sourceRow
                menu.addItem(asDelete)
                let dup = NSMenuItem(title: "Duplicate row (INSERT to clipboard)", action: #selector(handleRowDuplicate(_:)), keyEquivalent: "")
                dup.target = self
                dup.representedObject = sourceRow
                menu.addItem(dup)
                menu.addItem(.separator())
                let edit = NSMenuItem(title: "Edit cell…", action: #selector(handleEditMenu(_:)), keyEquivalent: "")
                edit.target = self
                edit.representedObject = CellLocator(row: sourceRow, col: dataCol)
                menu.addItem(edit)
                if column.nullable {
                    let setNull = NSMenuItem(title: "Set NULL", action: #selector(handleSetNull(_:)), keyEquivalent: "")
                    setNull.target = self
                    setNull.representedObject = CellLocator(row: sourceRow, col: dataCol)
                    menu.addItem(setNull)
                }
            }
            return menu
        }

        private struct CellLocator {
            let row: Int
            let col: Int
        }

        @objc private func handleCopy(_ sender: NSMenuItem) {
            guard let value = sender.representedObject as? String else { return }
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(value, forType: .string)
        }

        @objc private func handleEditMenu(_ sender: NSMenuItem) {
            guard let loc = sender.representedObject as? CellLocator,
                  let buffer = editBuffer, let table = tableView else { return }
            presentEditor(row: loc.row, col: loc.col, in: table, buffer: buffer)
        }

        @objc private func handleSetNull(_ sender: NSMenuItem) {
            guard let loc = sender.representedObject as? CellLocator,
                  let _ = editBuffer else { return }
            // `loc.row` is already a source-row index — see contextMenu.
            // Walk the visible rows to find the original cell value.
            let visibleRow = sourceRowIndices.firstIndex(of: loc.row) ?? loc.row
            let original = page.rows[visibleRow][loc.col]
            commit(row: loc.row, col: loc.col, original: original, newValue: nil)
            tableView?.reloadData()
        }

        @objc private func handleRowInsert(_ sender: NSMenuItem) {
            guard let r = sender.representedObject as? Int else { return }
            onCopyRowAsInsert?(r)
        }

        @objc private func handleRowDelete(_ sender: NSMenuItem) {
            guard let r = sender.representedObject as? Int else { return }
            onCopyRowAsDelete?(r)
        }

        @objc private func handleRowDuplicate(_ sender: NSMenuItem) {
            guard let r = sender.representedObject as? Int else { return }
            onDuplicateRow?(r)
        }

        @objc private func handleFilterToCell(_ sender: NSMenuItem) {
            guard let loc = sender.representedObject as? CellLocator else { return }
            onFilterEqualsCell?(loc.row, loc.col)
        }

        @objc private func handleFilterIsNull(_ sender: NSMenuItem) {
            guard let col = sender.representedObject as? Int else { return }
            onFilterColumn?(col, .isNull)
        }

        @objc private func handleFilterIsNotNull(_ sender: NSMenuItem) {
            guard let col = sender.representedObject as? Int else { return }
            onFilterColumn?(col, .isNotNull)
        }

        @objc private func handleCopyMarkdown(_ sender: NSMenuItem) { onCopyAsMarkdown?() }
        @objc private func handleCopySlack(_ sender: NSMenuItem) { onCopyAsSlack?() }

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
        func commit(row: Int, col: Int, original: String?, newValue: String?) {
            guard let buffer = editBuffer else { return }
            // No-op against the original: drop the pending entry so the
            // cell goes back to clean instead of carrying a fake-dirty
            // marker that points at the same value.
            if newValue == original {
                if buffer.isDirty(row: row, column: col) {
                    buffer.clearCell(row: row, column: col)
                    invalidateRenderCacheCell(sourceRow: row, dataCol: col)
                    reloadRow(row)
                }
                return
            }
            buffer.set(row: row, column: col, value: newValue)
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

    func makeCoordinator() -> Coordinator {
        Coordinator(page: page, editBuffer: editBuffer)
    }

    func makeNSView(context: Context) -> NSScrollView {
        let table = EditableTableView()
        // Modern look: skip the system "alternating row backgrounds"
        // (loud against dark mode, looks like a Tiger-era table) and
        // turn off NSTableView's built-in solid-blue selection bar in
        // favour of the soft tint our HoverableRowView paints itself.
        table.usesAlternatingRowBackgroundColors = false
        table.gridStyleMask = [.solidHorizontalGridLineMask]
        table.gridColor = NSColor.separatorColor.withAlphaComponent(0.18)
        table.allowsColumnReordering = true
        table.allowsColumnResizing = true
        table.columnAutoresizingStyle = .noColumnAutoresizing
        table.allowsMultipleSelection = true
        // Keep `selectionHighlightStyle` at its default (`.regular`):
        // forcing `.none` here disabled NSTableView's hit-test path
        // on macOS 15, which silently broke double-click editing.
        // `HoverableRowView` still overrides `drawSelection(in:)` to
        // paint a soft accent wash instead of the system blue bar, so
        // the visuals stay modern even though the selection model is
        // the standard one.
        // Small horizontal gap so column boundaries read as boundaries
        // instead of letting cells touch and look like one mash.
        table.intercellSpacing = NSSize(width: 8, height: 0)
        table.rowSizeStyle = .custom
        table.style = .plain
        table.backgroundColor = .clear
        table.headerView = TypedHeaderView()
        table.editBufferProvider = { [weak coord = context.coordinator] in coord?.editBuffer }
        table.contextMenuProvider = { [weak coord = context.coordinator] visibleRow, tableCol in
            // tableCol is in *table-column space* (gutter = 0); we want
            // a data-column index. Empty area / gutter column returns nil.
            let dataCol = tableCol - 1
            guard dataCol >= 0 else { return nil }
            return coord?.contextMenu(forVisibleRow: visibleRow, dataCol: dataCol)
        }
        table.onArrowMove = { [weak coord = context.coordinator] rdelta, cdelta in
            coord?.moveFocus(rowDelta: rdelta, colDelta: cdelta)
        }
        table.onEnterKey = { [weak coord = context.coordinator] in
            coord?.openEditorForFocus()
        }
        table.tsvCopyProvider = { [weak coord = context.coordinator] in
            coord?.copyAsTSV()
        }
        table.onCommandClick = { [weak coord = context.coordinator] visibleRow, dataCol in
            guard let coord else { return }
            let sourceRow = coord.sourceIndex(forVisibleRow: visibleRow)
            coord.onCommandClickCell?(sourceRow, dataCol)
        }

        applyColumns(to: table, coordinator: context.coordinator)
        table.dataSource = context.coordinator
        table.delegate = context.coordinator
        table.target = context.coordinator
        table.doubleAction = #selector(Coordinator.handleDoubleClick(_:))
        context.coordinator.rebuildIndex()
        context.coordinator.tableView = table
        propagateState(to: context.coordinator)
        // Persist column-width drags. The notification only fires on
        // user-driven resize (not programmatic), so the initial
        // applyColumns pass we just ran doesn't bounce-write.
        NotificationCenter.default.addObserver(
            context.coordinator,
            selector: #selector(Coordinator.columnDidResize(_:)),
            name: NSTableView.columnDidResizeNotification,
            object: table
        )

        let scroll = NSScrollView()
        scroll.documentView = table
        scroll.hasVerticalScroller = true
        scroll.hasHorizontalScroller = true
        scroll.borderType = .noBorder
        scroll.drawsBackground = false
        return scroll
    }

    private func propagateState(to coordinator: Coordinator) {
        coordinator.sourceRowIndices = sourceRowIndices
        coordinator.sortDirectionFor = sortDirectionFor
        coordinator.onHeaderClick = onHeaderClick
        coordinator.onCopyRowAsInsert = onCopyRowAsInsert
        coordinator.onCopyRowAsDelete = onCopyRowAsDelete
        coordinator.onDuplicateRow = onDuplicateRow
        coordinator.onFilterEqualsCell = onFilterEqualsCell
        coordinator.onFilterColumn = onFilterColumn
        coordinator.onCopyAsMarkdown = onCopyAsMarkdown
        coordinator.onCopyAsSlack = onCopyAsSlack
        coordinator.onCommandClickCell = onCommandClickCell
        coordinator.columnLayoutKey = columnLayoutKey
    }

    func updateNSView(_ scroll: NSScrollView, context: Context) {
        guard let table = scroll.documentView as? EditableTableView else { return }
        let identityChanged = !columnsMatch(coordinator: context.coordinator, new: page.columns)
        let editableChanged = (context.coordinator.editBuffer != nil) != (editBuffer != nil)
        // Detect the meaningful change set BEFORE we mutate the coordinator
        // — so we can decide whether to fire a full reloadData (slow)
        // or partial updates (cheap, scroll-safe).
        let rowCountChanged = context.coordinator.page.rows.count != page.rows.count
            || context.coordinator.sourceRowIndices.count != sourceRowIndices.count
        let appliedChanged = context.coordinator.appliedHighlights != appliedHighlights
        let editBufferRefChanged = context.coordinator.editBuffer !== editBuffer

        // If the page identity changed (different columns or fresh
        // fetch produced a different row count) the render cache no
        // longer corresponds to what the user is looking at.
        if identityChanged || rowCountChanged {
            context.coordinator.invalidateRenderCache()
        }
        context.coordinator.page = page
        context.coordinator.editBuffer = editBuffer
        context.coordinator.appliedHighlights = appliedHighlights
        context.coordinator.rebuildIndex()
        propagateState(to: context.coordinator)
        if identityChanged || sourceRowIndices.count != table.numberOfRows {
            context.coordinator.focusedRow = nil
            context.coordinator.focusedDataCol = nil
        }
        table.editBufferProvider = { [weak coord = context.coordinator] in coord?.editBuffer }
        table.contextMenuProvider = { [weak coord = context.coordinator] visibleRow, tableCol in
            let dataCol = tableCol - 1
            guard dataCol >= 0 else { return nil }
            return coord?.contextMenu(forVisibleRow: visibleRow, dataCol: dataCol)
        }
        table.onArrowMove = { [weak coord = context.coordinator] rdelta, cdelta in
            coord?.moveFocus(rowDelta: rdelta, colDelta: cdelta)
        }
        table.onEnterKey = { [weak coord = context.coordinator] in
            coord?.openEditorForFocus()
        }
        table.tsvCopyProvider = { [weak coord = context.coordinator] in
            coord?.copyAsTSV()
        }
        table.onCommandClick = { [weak coord = context.coordinator] visibleRow, dataCol in
            guard let coord else { return }
            let sourceRow = coord.sourceIndex(forVisibleRow: visibleRow)
            coord.onCommandClickCell?(sourceRow, dataCol)
        }
        if identityChanged || editableChanged {
            for col in table.tableColumns { table.removeTableColumn(col) }
            applyColumns(to: table, coordinator: context.coordinator)
            table.reloadData()
            return
        }
        // Cheap-path updates. SwiftUI calls updateNSView on *every*
        // observable change in the parent (dirty count, isRefreshing,
        // refreshError flicker, …) so the previous unconditional
        // `reloadData()` was tearing down + rebuilding every visible
        // row mid-scroll. Now we only reload when the data actually
        // changed shape.
        updateHeaderSortIndicators(table: table)
        if rowCountChanged {
            table.reloadData()
        } else if appliedChanged || editBufferRefChanged {
            // Repaint just the visible rows so the green-rail flash +
            // dirty-rail flip without nuking scroll position.
            let visible = table.rows(in: table.visibleRect)
            if visible.length > 0 {
                table.reloadData(
                    forRowIndexes: IndexSet(integersIn: visible.location..<(visible.location + visible.length)),
                    columnIndexes: IndexSet(integersIn: 0..<table.numberOfColumns)
                )
            }
        }
        // Otherwise: no reload. Cells repaint themselves on their own
        // bounds invalidations; per-cell edits already call
        // `reloadRow(_:)` from the commit path.
    }

    private func updateHeaderSortIndicators(table: NSTableView) {
        // Build a fresh TypedHeaderCell with the new sort direction
        // baked in. We can't mutate the existing cell — it has no
        // Swift fields by design (see the type's doc comment for the
        // NSCell-copy crash this avoids).
        for (i, tableCol) in table.tableColumns.enumerated() {
            if tableCol.identifier.rawValue == Coordinator.gutterColumnID { continue }
            let dataIdx = i - 1
            guard dataIdx >= 0, dataIdx < page.columns.count else { continue }
            let col = page.columns[dataIdx]
            let kind = ColumnTypeKind.from(typeName: col.typeName)
            tableCol.headerCell = TypedHeaderCell(
                title: col.name,
                typeLabel: col.typeName,
                alignment: headerAlignment(for: kind),
                sortDirection: sortDirectionFor?(col.name) ?? .none
            )
        }
        table.headerView?.needsDisplay = true
    }

    private func nameForColumn(identifier: String) -> String {
        if let underscore = identifier.firstIndex(of: "_") {
            return String(identifier[identifier.index(after: underscore)...])
        }
        return identifier
    }

    private func columnsMatch(coordinator: Coordinator, new: [ColumnNode]) -> Bool {
        guard coordinator.page.columns.count == new.count else { return false }
        return zip(coordinator.page.columns, new).allSatisfy { $0.name == $1.name && $0.typeName == $1.typeName }
    }

    private func applyColumns(to table: NSTableView, coordinator: Coordinator) {
        // Gutter first — fixed width, no resize, no reorder. The header
        // cell is empty since this column isn't a data column.
        let gutter = NSTableColumn(identifier: NSUserInterfaceItemIdentifier(Coordinator.gutterColumnID))
        gutter.minWidth = 48
        gutter.width = 48
        gutter.maxWidth = 64
        gutter.isEditable = false
        gutter.headerCell = NSTableHeaderCell(textCell: "")
        gutter.resizingMask = []
        table.addTableColumn(gutter)

        let editable = coordinator.editBuffer != nil
        for (i, col) in page.columns.enumerated() {
            let identifier = NSUserInterfaceItemIdentifier("\(i)_\(col.name)")
            let column = NSTableColumn(identifier: identifier)
            column.minWidth = 60
            // Persisted user-set width wins over the type-driven
            // default. Clamps to [minWidth, maxWidth] so a stale
            // outsize value can't break the grid.
            let saved = columnLayoutKey.flatMap { (id, sch, t) in
                ColumnLayoutStore.shared.width(connectionID: id, schema: sch, table: t, column: col.name)
            }
            let estimated = estimatedWidth(for: col)
            column.width = max(60, min(saved ?? estimated, 800))
            column.maxWidth = 800
            column.isEditable = editable
            let kind = ColumnTypeKind.from(typeName: col.typeName)
            // Custom header cell: column name on top, PG type as small
            // uppercase tag underneath, with an optional sort glyph.
            // Sort direction is baked in at construction — NSCell
            // copies don't carry Swift fields (see TypedHeaderCell).
            let cell = TypedHeaderCell(
                title: col.name,
                typeLabel: col.typeName,
                alignment: headerAlignment(for: kind),
                sortDirection: sortDirectionFor?(col.name) ?? .none
            )
            column.headerCell = cell
            table.addTableColumn(column)
        }
    }

    private func estimatedWidth(for col: ColumnNode) -> CGFloat {
        let kind = ColumnTypeKind.from(typeName: col.typeName)
        switch kind {
        case .bool: return 70
        case .integer: return 100
        case .number: return 120
        case .uuid: return 270
        case .timestamp: return 200
        case .date: return 130
        case .json: return 260
        default: return 180
        }
    }

    private func headerAlignment(for kind: ColumnTypeKind) -> NSTextAlignment {
        switch kind {
        case .integer, .number: return .right
        case .bool: return .center
        default: return .left
        }
    }
}

/// NSTableView subclass that routes ⌘Z to the bound EditBuffer so the user
/// can undo pending edits without involving the system undo manager, and
/// delegates right-click context-menu construction to the coordinator.
final class EditableTableView: NSTableView {
    var editBufferProvider: (() -> EditBuffer?)?
    /// `(row, col) → menu?` — the coordinator builds the menu lazily so it
    /// can read the current page + edit buffer without us re-plumbing
    /// state into this subclass.
    var contextMenuProvider: ((Int, Int) -> NSMenu?)?
    /// Keyboard navigation hook — called with (rowDelta, colDelta).
    var onArrowMove: ((Int, Int) -> Void)?
    /// Called when Return/Enter is pressed on the focused cell.
    var onEnterKey: (() -> Void)?
    /// Called to produce TSV for the current selection; result lands on
    /// the system pasteboard.
    var tsvCopyProvider: (() -> String?)?
    /// ⌘-click navigation hook — fires when the user ⌘-clicks a
    /// single cell. Caller resolves whether the cell is a foreign
    /// key and routes to the parent table if so. `visibleRow` is the
    /// row in the currently-filtered view; `dataCol` is 0-indexed
    /// over data columns (not including the gutter).
    var onCommandClick: ((Int, Int) -> Void)?

    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        let chars = event.charactersIgnoringModifiers ?? ""
        let cmd = event.modifierFlags.contains(.command)
        let shift = event.modifierFlags.contains(.shift)
        if cmd, !shift, chars == "z" {
            if let buffer = editBufferProvider?(), buffer.canUndo {
                _ = buffer.undo()
                reloadData()
                return true
            }
        }
        // ⌘C → TSV of the current selection (rows × visible data columns).
        if cmd, !shift, chars == "c" {
            if let tsv = tsvCopyProvider?(), !tsv.isEmpty {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(tsv, forType: .string)
                return true
            }
        }
        return super.performKeyEquivalent(with: event)
    }

    override func mouseDown(with event: NSEvent) {
        // ⌘-click → fire the FK-navigation hook on the cell under
        // the cursor. Falls through to NSTableView's normal click
        // handling otherwise.
        if event.modifierFlags.contains(.command), event.clickCount == 1,
           let handler = onCommandClick {
            let point = convert(event.locationInWindow, from: nil)
            let row = self.row(at: point)
            let tableCol = self.column(at: point)
            // tableCol 0 is the gutter; anything past it is a data
            // column index N → dataCol N-1.
            if row >= 0, tableCol > 0 {
                handler(row, tableCol - 1)
                return
            }
        }
        super.mouseDown(with: event)
    }

    override func keyDown(with event: NSEvent) {
        // Arrow keys move the cell-focus; Enter opens the popover.
        switch event.keyCode {
        case 123: onArrowMove?(0, -1); return  // ←
        case 124: onArrowMove?(0, 1);  return  // →
        case 125: onArrowMove?(1, 0);  return  // ↓
        case 126: onArrowMove?(-1, 0); return  // ↑
        case 36, 76:  // Return / numpad Enter
            onEnterKey?(); return
        default: break
        }
        super.keyDown(with: event)
    }

    override var acceptsFirstResponder: Bool { true }

    override func menu(for event: NSEvent) -> NSMenu? {
        let point = convert(event.locationInWindow, from: nil)
        let row = self.row(at: point)
        let col = self.column(at: point)
        if row >= 0, col >= 0 {
            // Select the right-clicked row for visual anchoring.
            selectRowIndexes(IndexSet(integer: row), byExtendingSelection: false)
            return contextMenuProvider?(row, col)
        }
        return super.menu(for: event)
    }
}

/// Row view that paints subtle hover + selection tints. NSTableView's
/// built-in `.inset` selection is a loud solid-blue bar (very
/// pre-modern); we run with `selectionHighlightStyle = .none` and
/// draw both states ourselves with soft accent washes that read well
/// in light and dark mode alike.
final class HoverableRowView: NSTableRowView {
    private var isHovered = false {
        didSet { if oldValue != isHovered { needsDisplay = true } }
    }
    private var trackingArea: NSTrackingArea?

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        // Tracking areas with `.inVisibleRect` follow bounds without
        // being rebuilt, so we only need to install one ever. The
        // previous code recreated the area on every layout pass and
        // tableview row-recycling triggers a lot of layout passes
        // mid-scroll — visible as the "clunky" feel the user reported.
        if trackingArea != nil { return }
        let area = NSTrackingArea(
            rect: bounds,
            options: [.mouseEnteredAndExited, .activeInActiveApp, .inVisibleRect],
            owner: self, userInfo: nil
        )
        addTrackingArea(area)
        trackingArea = area
    }

    override func mouseEntered(with event: NSEvent) { isHovered = true }
    override func mouseExited(with event: NSEvent) { isHovered = false }

    /// NSTableView recycles row views — when a row view is detached
    /// from its old visible row and reattached to a new one, the
    /// hover state from the old row would leak through until the
    /// mouse moves. Reset on each prepare.
    override func prepareForReuse() {
        super.prepareForReuse()
        isHovered = false
    }

    override func drawBackground(in dirtyRect: NSRect) {
        super.drawBackground(in: dirtyRect)
        if isHovered && !isSelected {
            NSColor.controlAccentColor.withAlphaComponent(0.06).setFill()
            bounds.fill()
        }
    }

    /// Replace the system's solid-blue selection bar with a soft accent
    /// wash + a 2pt leading strip. NSTableView still drives selection
    /// state (so double-click editing and arrow nav keep working);
    /// we just intercept the paint here for a modern look.
    override func drawSelection(in dirtyRect: NSRect) {
        guard isSelected else { return }
        NSColor.controlAccentColor.withAlphaComponent(0.14).setFill()
        bounds.fill()
        NSColor.controlAccentColor.withAlphaComponent(0.85).setFill()
        NSRect(x: 0, y: 0, width: 2, height: bounds.height).fill()
    }
}

/// Fixed-width leftmost column showing the 1-based row number. Mirrors
/// the JetBrains gutter — secondary background, monospaced digits,
/// right-aligned. Highlights when its row carries the keyboard focus.
final class RowNumberCellView: NSTableCellView {
    private let label = NSTextField(labelWithString: "")
    private var isFocused = false {
        didSet { needsDisplay = true }
    }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        label.translatesAutoresizingMaskIntoConstraints = false
        label.font = NSFont.monospacedDigitSystemFont(ofSize: 11, weight: .regular)
        label.textColor = .tertiaryLabelColor
        label.alignment = .right
        addSubview(label)
        NSLayoutConstraint.activate([
            label.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -8),
            label.centerYAnchor.constraint(equalTo: centerYAnchor),
        ])
    }

    required init?(coder: NSCoder) { fatalError() }

    func configure(rowNumber: Int, isFocused: Bool) {
        label.stringValue = String(rowNumber)
        self.isFocused = isFocused
        label.textColor = isFocused ? .labelColor : .tertiaryLabelColor
        needsDisplay = true
    }

    override func draw(_ dirtyRect: NSRect) {
        // Subtle gutter band — barely-tinted relative to the data
        // area, just enough to read as "row index". The old version
        // used a 50%-blended controlBackgroundColor which came out
        // near-black on dark mode and dominated the table.
        NSColor.separatorColor.withAlphaComponent(0.06).setFill()
        bounds.fill()
        // Right-edge separator.
        NSColor.separatorColor.withAlphaComponent(0.35).setFill()
        NSRect(x: bounds.maxX - 0.5, y: 0, width: 0.5, height: bounds.height).fill()
        if isFocused {
            // Brand-violet accent strip on the right edge of the gutter.
            #colorLiteral(red: 0.42, green: 0.32, blue: 0.86, alpha: 0.85).setFill()
            NSRect(x: bounds.maxX - 2, y: 0, width: 2, height: bounds.height).fill()
        }
        super.draw(dirtyRect)
    }
}

/// One reusable cell view that styles itself based on the column kind and
/// whether the host grid is editable. Editing uses a borderless text field
/// the table view promotes to first responder on double-click.
private final class DataCellView: NSTableCellView, NSTextFieldDelegate {
    private let field = EditingTextField()
    private var currentKind: ColumnTypeKind = .unknown
    private var currentValueIsNull = false
    private var lastConfiguredText: String = ""
    private var isCancelling = false
    private var isDirty = false
    private var isRecentlyApplied = false
    private var isFocused = false
    /// Identity of the last NSAttributedString we assigned to the
    /// field, so configure() can skip the re-assignment (and the
    /// layout invalidation that comes with it) when the coordinator
    /// hands us the same cached Rendered.
    private var lastAttributedID: ObjectIdentifier?
    /// Cached tooltip string — set with `setToolTip` only when it
    /// actually changes. (Setting the same toolTip is technically
    /// cheap, but every per-cell write during a recycle storm shows
    /// up in profiles.)
    private var lastToolTip: String?
    var onCommit: ((String) -> Void)?

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        // Manual frame layout — AutoLayout per cell × per scroll tick
        // adds up to the dominant cost during fast scrolling. We set
        // the field's frame directly in `layout()` instead.
        field.translatesAutoresizingMaskIntoConstraints = true
        field.autoresizingMask = []
        field.isBordered = false
        field.isBezeled = false
        field.drawsBackground = false
        field.focusRingType = .none
        field.lineBreakMode = .byTruncatingTail
        // NOTE: deliberately NOT setting `usesSingleLineMode = true`.
        // That cell flag flattens attributed-string per-range attributes
        // into the cell's plain defaults.
        field.cell?.isScrollable = true
        field.delegate = self
        addSubview(field)
        self.textField = field
    }

    required init?(coder: NSCoder) { fatalError() }

    override func layout() {
        super.layout()
        // 8pt left inset leaves room for the dirty/applied rail, 6pt
        // right inset stops content from kissing the column boundary.
        let inset = NSEdgeInsets(top: 0, left: 8, bottom: 0, right: 6)
        let h = NSFont.systemFont(ofSize: 12).boundingRectForFont.height + 2
        field.frame = NSRect(
            x: inset.left,
            y: (bounds.height - h) / 2,
            width: max(0, bounds.width - inset.left - inset.right),
            height: h
        )
    }

    override func prepareForReuse() {
        super.prepareForReuse()
        // Drop the dedupe caches so the recycled cell rebinds from
        // scratch against whatever row it's now serving.
        lastAttributedID = nil
        lastToolTip = nil
    }

    override func draw(_ dirtyRect: NSRect) {
        // Common-case fast path: the cell has no dirty / applied /
        // focused state to render, so skip every custom op and let
        // AppKit's default draw run uninterrupted. This is what
        // 99% of cells are during a scroll storm.
        if !isDirty && !isRecentlyApplied && !isFocused {
            super.draw(dirtyRect)
            return
        }
        if isDirty {
            NSColor.systemYellow.withAlphaComponent(0.10).setFill()
            bounds.fill()
        } else if isRecentlyApplied {
            NSColor.systemGreen.withAlphaComponent(0.16).setFill()
            bounds.fill()
        }
        super.draw(dirtyRect)
        if isDirty {
            NSColor.systemYellow.setFill()
            NSRect(x: 0, y: 0, width: 3, height: bounds.height).fill()
        } else if isRecentlyApplied {
            NSColor.systemGreen.setFill()
            NSRect(x: 0, y: 0, width: 3, height: bounds.height).fill()
        }
        if isFocused {
            let path = NSBezierPath(roundedRect: bounds.insetBy(dx: 1, dy: 1), xRadius: 3, yRadius: 3)
            path.lineWidth = 1.5
            #colorLiteral(red: 0.42, green: 0.32, blue: 0.86, alpha: 0.9).setStroke()
            path.stroke()
        }
    }

    private var rawForEditor: String = ""

    /// Fast configure — takes a pre-rendered attributed string from
    /// the coordinator's render cache instead of re-running the
    /// formatter on every recycle. Skips redundant per-cell writes
    /// (attributed string, tooltip, needsDisplay) when nothing
    /// visually changed since the previous configure.
    func configure(rendered: CellFormat.Rendered, isDirty: Bool, isRecentlyApplied: Bool, isFocused: Bool, isNull: Bool) {
        currentValueIsNull = isNull
        // These are cheap idempotent property writes; leave alone.
        field.isEditable = false
        field.isSelectable = true

        // Only mark for redisplay if a visual state ACTUALLY changed.
        // Most cell recycles during scroll have identical state to
        // the previous occupant — letting AppKit skip the redraw is
        // the big scroll-fps win.
        let stateChanged = (self.isDirty != isDirty)
            || (self.isRecentlyApplied != isRecentlyApplied)
            || (self.isFocused != isFocused)
        self.isDirty = isDirty
        self.isRecentlyApplied = isRecentlyApplied
        self.isFocused = isFocused

        // Skip the attributedStringValue set when the coordinator's
        // render cache handed us the same NSAttributedString as last
        // time — NSTextField's setter triggers cell-content layout
        // invalidation that's not free.
        let nextID = ObjectIdentifier(rendered.attributed)
        if lastAttributedID != nextID {
            field.placeholderString = nil
            field.attributedStringValue = rendered.attributed
            lastAttributedID = nextID
            lastConfiguredText = rendered.attributed.string
            rawForEditor = rendered.rawForEditor
        }

        // Long-text tooltip — only changed when the string changed.
        let nextToolTip: String? = {
            if rendered.attributed.length > 32 || rendered.attributed.string.contains("\n") {
                return rendered.rawForEditor
            }
            return nil
        }()
        if lastToolTip != nextToolTip {
            self.toolTip = nextToolTip
            lastToolTip = nextToolTip
        }

        if stateChanged { needsDisplay = true }
    }

    func controlTextDidBeginEditing(_ notif: Notification) {
        // Editor receives the *raw* value the server gave us — not the
        // formatted display. So bool widgets become "true"/"false", dates
        // come back to their ISO string, etc.
        field.stringValue = rawForEditor
        field.textColor = .labelColor
        field.font = font(for: currentKind)
    }

    func controlTextDidEndEditing(_ notif: Notification) {
        if isCancelling {
            // Esc: restore the rendered text and don't propagate a commit.
            isCancelling = false
            field.stringValue = lastConfiguredText
            return
        }
        onCommit?(field.stringValue)
    }

    // Esc → cancel edits; AppKit calls this on the field editor's delegate.
    func control(_ control: NSControl, textView: NSTextView, doCommandBy commandSelector: Selector) -> Bool {
        if commandSelector == #selector(NSResponder.cancelOperation(_:)) {
            isCancelling = true
            field.stringValue = lastConfiguredText
            window?.makeFirstResponder(enclosingTableView)
            return true
        }
        return false
    }

    /// Walk up the view hierarchy to find the host `NSTableView` — used by
    /// Esc-cancel so we can hand first-responder back cleanly.
    private var enclosingTableView: NSTableView? {
        var view: NSView? = superview
        while let v = view {
            if let t = v as? NSTableView { return t }
            view = v.superview
        }
        return nil
    }

    private func alignment(for kind: ColumnTypeKind) -> NSTextAlignment {
        switch kind {
        case .integer, .number: return .right
        case .bool: return .center
        default: return .left
        }
    }

    private func font(for kind: ColumnTypeKind) -> NSFont {
        switch kind {
        case .integer, .number, .uuid, .json, .bytes, .timestamp:
            return NSFont.monospacedSystemFont(ofSize: 12, weight: .regular)
        default:
            return NSFont.systemFont(ofSize: 12)
        }
    }

    private func boolGlyph(for raw: String) -> String {
        switch raw.lowercased() {
        case "t", "true", "1": return "✓"
        case "f", "false", "0": return ""
        default: return raw
        }
    }
}

/// NSTextField that, when first responder, draws a faint border so the user
/// can see which cell they're typing into.
private final class EditingTextField: NSTextField {
    override func becomeFirstResponder() -> Bool {
        let ok = super.becomeFirstResponder()
        if ok { needsDisplay = true }
        return ok
    }
}

private extension NSFont {
    func italic() -> NSFont {
        let descriptor = fontDescriptor.withSymbolicTraits(.italic)
        return NSFont(descriptor: descriptor, size: pointSize) ?? self
    }
}

/// Header cell that stacks a bold column name on top of a small
/// uppercase PG type tag — `name` / `INTEGER`, `email` / `TEXT`, etc.
///
/// All state goes into `attributedStringValue` (a real NSCell ivar that
/// survives `copy(with:)` correctly). Earlier versions stored Swift
/// properties on the subclass; AppKit silently copies header cells for
/// every redraw and the default `NSCopying` doesn't carry custom Swift
/// fields, so those copies pointed at freed memory and crashed on the
/// second draw.
/// Two-line header cell — bold column name on top, small uppercase PG
/// type tag underneath, optional sort arrow on the trailing edge of the
/// name line. **Deliberately stores zero Swift fields**: NSTableView
/// copies header cells via `NSCell.copy(with:)` during draw cycles, and
/// Swift stored properties on a subclass don't carry across that copy
/// (the copy's memory for our fields is uninitialised). Touching them
/// in a deinit chain crashes with EXC_BAD_ACCESS in `outlined destroy
/// of String`. Everything goes into `attributedStringValue` (a real
/// NSCell ivar that NSCopying handles correctly); sort-direction
/// changes are applied by *replacing* the cell (see
/// `updateHeaderSortIndicators`), not by mutating one.
final class TypedHeaderCell: NSTableHeaderCell {
    enum SortDirection {
        case none, ascending, descending
        var glyph: String {
            switch self {
            case .none:       ""
            case .ascending:  "  ↑"
            case .descending: "  ↓"
            }
        }
    }

    init(title: String, typeLabel: String, alignment: NSTextAlignment, sortDirection: SortDirection = .none) {
        super.init(textCell: "")
        self.alignment = alignment
        let attr = NSMutableAttributedString()
        let nameAttrs: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: 12, weight: .semibold),
            .foregroundColor: sortDirection == .none
                ? NSColor.labelColor
                : #colorLiteral(red: 0.42, green: 0.32, blue: 0.86, alpha: 1.0),
        ]
        let typeAttrs: [NSAttributedString.Key: Any] = [
            .font: NSFont.monospacedSystemFont(ofSize: 9, weight: .medium),
            .foregroundColor: NSColor.tertiaryLabelColor,
            .kern: NSNumber(value: 0.4),
        ]
        let glyphAttrs: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: 11, weight: .semibold),
            .foregroundColor: #colorLiteral(red: 0.42, green: 0.32, blue: 0.86, alpha: 1.0),
        ]
        attr.append(NSAttributedString(string: title, attributes: nameAttrs))
        if sortDirection != .none {
            attr.append(NSAttributedString(string: sortDirection.glyph, attributes: glyphAttrs))
        }
        attr.append(NSAttributedString(string: "\n", attributes: nameAttrs))
        attr.append(NSAttributedString(string: typeLabel.uppercased(), attributes: typeAttrs))
        let para = NSMutableParagraphStyle()
        para.alignment = alignment
        para.lineSpacing = 0
        para.lineBreakMode = .byClipping
        attr.addAttribute(.paragraphStyle, value: para,
                          range: NSRange(location: 0, length: attr.length))
        self.attributedStringValue = attr
    }
    required init(coder: NSCoder) { fatalError() }
}

/// Header view sized for the two-line title cells (column name +
/// uppercase PG type tag). The JetBrains-style WHERE / ORDER BY strip
/// lives in `TableTabView` above the grid — not inside the header — so
/// it can be a single full-width split instead of one input per column.
final class TypedHeaderView: NSTableHeaderView {
    override var intrinsicContentSize: NSSize {
        NSSize(width: NSView.noIntrinsicMetric, height: 36)
    }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        self.frame = NSRect(origin: frameRect.origin,
                            size: NSSize(width: frameRect.width, height: 36))
    }
    required init?(coder: NSCoder) { fatalError() }
}
