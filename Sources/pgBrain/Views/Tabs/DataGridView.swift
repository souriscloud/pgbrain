import AppKit
import SwiftUI

/// Quick-filter modes wired into the grid's context menus. Receivers compose
/// the corresponding `col IS NULL` / `col IS NOT NULL` fragment.
enum ColumnFilterMode {
    case isNull, isNotNull
}

/// `NSTableView` driven by a `RowsFetcher.Page`: type-aware cells, a row
/// gutter, spreadsheet-style cell/range selection, keyboard editing and
/// TSV copy / paste.
///
/// Pass an `EditBuffer` to make it editable (a table tab); leave it nil for
/// read-only result grids (scratchpad).
///
/// Row coordinates: *visible* rows index `page.rows` (which may be the
/// find-filtered subset); `sourceRowIndices` maps them back to the loaded
/// page, which is what the edit buffer, insert/delete sets and callbacks use.
struct DataGridView: NSViewRepresentable {
    let page: RowsFetcher.Page
    var editBuffer: EditBuffer? = nil
    /// `editBuffer.version`, read by the parent so SwiftUI re-renders the
    /// grid on any buffer change (undo from the Edit menu, form edits…).
    var editVersion: Int = 0
    var enums: [String: [String]] = [:]
    var schema: SchemaSnapshot = .empty
    var appliedHighlights: Set<EditBuffer.CellKey> = []
    var insertRowIndices: Set<Int> = []
    var deleteRowIndices: Set<Int> = []
    var sourceRowIndices: [Int] = []
    /// Identity of the loaded page: a change means a new fetch (reset
    /// selection, scroll to top, drop cached cells). Nil for callers that
    /// don't track one; the grid then compares row contents instead.
    var pageGeneration: Int? = nil
    /// In-place row changes (apply splice-back, draft rows) — reload, keep
    /// the selection.
    var contentRevision: Int = 0
    var focusRequest: RowsLoader.FocusRequest? = nil
    /// Where the grid parks scroll offset / cursor across tab switches.
    var viewState: TableTabViewState? = nil
    /// Columns whose ⌘-click follows a foreign key instead of adding the
    /// cell to the selection.
    var foreignKeyColumns: Set<String> = []
    /// Enables the INSERT / UPDATE / DELETE "Copy rows as" formats.
    var copyTarget: RowCopy.Target? = nil
    var sortDirectionFor: ((String) -> TypedHeaderCell.SortDirection)? = nil
    var onHeaderClick: ((String, TypedHeaderCell.SortDirection) -> Void)? = nil
    var onFilterEqualsCell: ((Int /*sourceRow*/, Int /*dataCol*/) -> Void)? = nil
    var onFilterColumn: ((Int /*dataCol*/, ColumnFilterMode) -> Void)? = nil
    var onShowColumnDistinct: ((String) -> Void)? = nil
    /// Column profiler popover content for a column name, presented
    /// anchored to that column's header. Nil hides the menu entry.
    var makeProfilerController: ((String) -> NSViewController?)? = nil
    var onDeleteRows: (([Int]) -> Void)? = nil
    var onDuplicateRows: (([Int]) -> Void)? = nil
    var onAddRow: (() -> Void)? = nil
    var onNavigateForeignKey: ((Int /*sourceRow*/, Int /*dataCol*/) -> Void)? = nil
    /// Short user-facing feedback (paste clipped, NOT NULL refused…).
    var onMessage: ((String, Bool /*isError*/) -> Void)? = nil
    /// `(connectionID, schema, table)` keying persisted column widths.
    var columnLayoutKey: (UUID, String, String)? = nil

    /// Row height derived from the editor font size so the grid breathes as
    /// it zooms.
    static func gridRowHeight() -> CGFloat { (CellFormat.baseSize).rounded() + 10 }

    func makeCoordinator() -> Coordinator {
        Coordinator(page: page, editBuffer: editBuffer)
    }

    func makeNSView(context: Context) -> NSScrollView {
        let coordinator = context.coordinator
        let table = EditableTableView()
        table.usesAlternatingRowBackgroundColors = false
        table.gridStyleMask = [.solidHorizontalGridLineMask]
        table.gridColor = NSColor.separatorColor.withAlphaComponent(0.18)
        table.allowsColumnReordering = true
        table.allowsColumnResizing = true
        table.columnAutoresizingStyle = .noColumnAutoresizing
        table.allowsMultipleSelection = true
        table.allowsEmptySelection = true
        table.intercellSpacing = NSSize(width: 8, height: 0)
        table.rowSizeStyle = .custom
        table.style = .plain
        table.backgroundColor = .clear
        table.rowHeight = Self.gridRowHeight()
        let header = TypedHeaderView()
        header.coordinator = coordinator
        table.headerView = header

        push(into: coordinator)
        coordinator.pageGeneration = pageGeneration
        coordinator.contentRevision = contentRevision
        coordinator.tableView = table
        table.handler = coordinator
        applyColumns(to: table, coordinator: coordinator)
        table.dataSource = coordinator
        table.delegate = coordinator

        NotificationCenter.default.addObserver(
            coordinator, selector: #selector(Coordinator.columnDidResize(_:)),
            name: NSTableView.columnDidResizeNotification, object: table)
        NotificationCenter.default.addObserver(
            coordinator, selector: #selector(Coordinator.columnDidMove(_:)),
            name: NSTableView.columnDidMoveNotification, object: table)
        NotificationCenter.default.addObserver(
            coordinator, selector: #selector(Coordinator.editorFontDidChange),
            name: .pgbrainEditorFontChanged, object: nil)

        let scroll = NSScrollView()
        scroll.documentView = table
        scroll.hasVerticalScroller = true
        scroll.hasHorizontalScroller = true
        scroll.borderType = .noBorder
        scroll.drawsBackground = false
        scroll.contentView.postsBoundsChangedNotifications = true
        NotificationCenter.default.addObserver(
            coordinator, selector: #selector(Coordinator.clipViewDidScroll(_:)),
            name: NSView.boundsDidChangeNotification, object: scroll.contentView)

        table.reloadData()
        coordinator.restoreViewState(in: scroll)
        // A request left over from before a tab switch was already honoured
        // by the previous grid; a remount shouldn't jump there again.
        coordinator.markSeen(focusRequest)
        return scroll
    }

    /// Copy the representable's inputs onto the coordinator.
    private func push(into c: Coordinator) {
        c.page = page
        c.editBuffer = editBuffer
        c.editVersion = editVersion
        c.enums = enums
        c.schema = schema
        c.appliedHighlights = appliedHighlights
        c.insertRowIndices = insertRowIndices
        c.deleteRowIndices = deleteRowIndices
        c.sourceRowIndices = effectiveSourceIndices
        c.viewState = viewState
        c.foreignKeyColumns = foreignKeyColumns
        c.copyTarget = copyTarget
        c.sortDirectionFor = sortDirectionFor
        c.onHeaderClick = onHeaderClick
        c.onFilterEqualsCell = onFilterEqualsCell
        c.onFilterColumn = onFilterColumn
        c.onShowColumnDistinct = onShowColumnDistinct
        c.makeProfilerController = makeProfilerController
        c.onDeleteRows = onDeleteRows
        c.onDuplicateRows = onDuplicateRows
        c.onAddRow = onAddRow
        c.onNavigateForeignKey = onNavigateForeignKey
        c.onMessage = onMessage
        c.columnLayoutKey = columnLayoutKey
        c.rebuildSourceLookup()
    }

    private var effectiveSourceIndices: [Int] {
        sourceRowIndices.count == page.rows.count ? sourceRowIndices : Array(0..<page.rows.count)
    }

    func updateNSView(_ scroll: NSScrollView, context: Context) {
        guard let table = scroll.documentView as? EditableTableView else { return }
        let c = context.coordinator
        let columnsChanged = !columnsMatch(c.page.columns, page.columns)
            || (c.editBuffer != nil) != (editBuffer != nil)
        let generationChanged: Bool = {
            if let pageGeneration { return pageGeneration != c.pageGeneration }
            return c.page.rows.count != page.rows.count
                || c.page.rows.first != page.rows.first
                || c.page.rows.last != page.rows.last
        }()
        let sourcesChanged = effectiveSourceIndices != c.sourceRowIndices
        let shapeChanged = contentRevision != c.contentRevision || c.page.rows.count != page.rows.count
        let paintChanged = appliedHighlights != c.appliedHighlights
            || insertRowIndices != c.insertRowIndices
            || deleteRowIndices != c.deleteRowIndices
            || editVersion != c.editVersion
            || editBuffer !== c.editBuffer

        push(into: c)
        c.pageGeneration = pageGeneration
        c.contentRevision = contentRevision

        if columnsChanged {
            for col in table.tableColumns { table.removeTableColumn(col) }
            applyColumns(to: table, coordinator: c)
            c.invalidateRenderCache()
            c.resetSelection()
            table.reloadData()
            if table.numberOfRows > 0 { table.scrollRowToVisible(0) }
        } else {
            updateHeaderSortIndicators(table: table)
            if generationChanged {
                c.invalidateRenderCache()
                c.resetSelection()
                table.reloadData()
                if table.numberOfRows > 0 { table.scrollRowToVisible(0) }
            } else if shapeChanged || sourcesChanged {
                if sourcesChanged { c.resetSelection() } else { c.clampSelection() }
                table.reloadData()
                c.syncRowSelection()
            } else if paintChanged {
                c.reloadVisibleRows()
            }
        }
        c.handle(focusRequest)
    }

    private func updateHeaderSortIndicators(table: NSTableView) {
        // TypedHeaderCell keeps no Swift state (NSCell copies would crash),
        // so a new sort arrow means a new cell.
        for tableCol in table.tableColumns {
            guard let dataIdx = Coordinator.dataIndex(of: tableCol), dataIdx < page.columns.count else { continue }
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

    private func columnsMatch(_ old: [ColumnNode], _ new: [ColumnNode]) -> Bool {
        guard old.count == new.count else { return false }
        return zip(old, new).allSatisfy { $0.name == $1.name && $0.typeName == $1.typeName }
    }

    private func applyColumns(to table: NSTableView, coordinator: Coordinator) {
        let gutter = NSTableColumn(identifier: NSUserInterfaceItemIdentifier(Coordinator.gutterColumnID))
        gutter.minWidth = 48
        gutter.width = 48
        gutter.maxWidth = 64
        gutter.isEditable = false
        gutter.headerCell = NSTableHeaderCell(textCell: "")
        gutter.resizingMask = []
        table.addTableColumn(gutter)

        for (i, col) in page.columns.enumerated() {
            let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier(Coordinator.identifier(forDataCol: i, name: col.name)))
            column.minWidth = 60
            // A persisted user width beats the type-driven estimate; clamped
            // so a stale outsize value can't break the grid.
            let saved = columnLayoutKey.flatMap { (id, sch, t) in
                ColumnLayoutStore.shared.width(connectionID: id, schema: sch, table: t, column: col.name)
            }
            column.width = max(60, min(saved ?? estimatedWidth(for: col), 800))
            column.maxWidth = 800
            column.isEditable = false
            let kind = ColumnTypeKind.from(typeName: col.typeName)
            column.headerCell = TypedHeaderCell(
                title: col.name,
                typeLabel: col.typeName,
                alignment: headerAlignment(for: kind),
                sortDirection: sortDirectionFor?(col.name) ?? .none
            )
            table.addTableColumn(column)
        }
        coordinator.rebuildColumnMap()
    }

    private func estimatedWidth(for col: ColumnNode) -> CGFloat {
        switch ColumnTypeKind.from(typeName: col.typeName) {
        case .bool: return 70
        case .integer: return 100
        case .number: return 120
        case .uuid: return 270
        case .timestamp: return 230
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
