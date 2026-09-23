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
    /// Enum type → labels catalog (from the connection's schema snapshot),
    /// so the cell editor can offer enum-column dropdowns.
    var enums: [String: [String]] = [:]
    /// Schema snapshot, so the cell editor's expression mode can offer
    /// schema-aware completion (this table's columns + functions).
    var schema: SchemaSnapshot = .empty
    /// `(row, column)` cells that were just successfully applied. Cell
    /// rendering paints them with a fading green tint for a few seconds
    /// so the user can see exactly what landed.
    var appliedHighlights: Set<EditBuffer.CellKey> = []
    /// Source-row indices that are draft INSERTs — drawn with a green wash
    /// and a ✦ in the gutter so a not-yet-committed row reads as new.
    var insertRowIndices: Set<Int> = []
    /// Source-row indices staged for DELETE — drawn with a red wash until
    /// the next Apply commits (or Revert clears) them.
    var deleteRowIndices: Set<Int> = []
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
    /// "Show distinct values" cell-menu action. Receiver runs
    /// `SELECT col, COUNT(*) GROUP BY 1 ORDER BY 2 DESC` and pops a
    /// list. Nil hides the menu entry (scratchpad result grids etc.).
    var onShowColumnDistinct: ((String) -> Void)? = nil
    /// Profile a column (counts, nulls, distinct, min/max/avg). Returns the
    /// popover content controller for a given column name, which the grid
    /// presents as an `NSPopover` anchored to that column's header (so it
    /// points at the column instead of floating off the grid bounds). Nil
    /// hides the menu entry on grids without a backing table (scratchpad
    /// results).
    var makeProfilerController: ((String) -> NSViewController?)? = nil
    /// Delete the given source-row indices. Nil hides the menu entry
    /// (read-only grids — scratchpad results, no edit buffer).
    var onDeleteRows: (([Int]) -> Void)? = nil
    /// `(connectionID, schema, table)` for the column-layout store
    /// keying. Nil disables persisted widths (e.g. for scratchpad
    /// result grids that don't have a stable table identity).
    var columnLayoutKey: (UUID, String, String)? = nil

    /// Row height derived from the editor font size so the grid breathes as
    /// it zooms. Kept in one place so makeNSView and the live-zoom handler agree.
    static func gridRowHeight() -> CGFloat { (CellFormat.baseSize).rounded() + 10 }

    func makeCoordinator() -> Coordinator {
        let c = Coordinator(page: page, editBuffer: editBuffer)
        c.enums = enums
        c.schema = schema
        return c
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
        let header = TypedHeaderView()
        header.coordinator = context.coordinator
        table.headerView = header
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
        table.onDeleteSelectedRows = { [weak coord = context.coordinator, weak table] in
            guard let coord, let table, let onDelete = coord.onDeleteRows else { return }
            let selected = table.selectedRowIndexes
            guard !selected.isEmpty else { return }
            onDelete(selected.map { coord.sourceIndex(forVisibleRow: $0) })
        }
        table.onSetNull = { [weak coord = context.coordinator] in coord?.setNullForFocusedCell() }
        table.hoverPreviewProvider = { [weak coord = context.coordinator] visibleRow, dataCol in
            coord?.hoverPreview(forVisibleRow: visibleRow, dataCol: dataCol)
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
        // Live ⌘+ / ⌘− zoom: re-render + re-height the grid when the editor
        // font size changes. Selector-based observers auto-deregister on the
        // coordinator's dealloc.
        NotificationCenter.default.addObserver(
            context.coordinator,
            selector: #selector(Coordinator.editorFontDidChange),
            name: .pgbrainEditorFontChanged,
            object: nil
        )
        table.rowHeight = Self.gridRowHeight()

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
        coordinator.onShowColumnDistinct = onShowColumnDistinct
        coordinator.makeProfilerController = makeProfilerController
        coordinator.onDeleteRows = onDeleteRows
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
        context.coordinator.enums = enums
        context.coordinator.schema = schema
        context.coordinator.appliedHighlights = appliedHighlights
        context.coordinator.insertRowIndices = insertRowIndices
        context.coordinator.deleteRowIndices = deleteRowIndices
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
        table.onDeleteSelectedRows = { [weak coord = context.coordinator, weak table] in
            guard let coord, let table, let onDelete = coord.onDeleteRows else { return }
            let selected = table.selectedRowIndexes
            guard !selected.isEmpty else { return }
            onDelete(selected.map { coord.sourceIndex(forVisibleRow: $0) })
        }
        table.onSetNull = { [weak coord = context.coordinator] in coord?.setNullForFocusedCell() }
        table.hoverPreviewProvider = { [weak coord = context.coordinator] visibleRow, dataCol in
            coord?.hoverPreview(forVisibleRow: visibleRow, dataCol: dataCol)
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
