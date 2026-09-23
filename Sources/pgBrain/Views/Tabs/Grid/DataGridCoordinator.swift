import AppKit
import SwiftUI

extension DataGridView {
    /// Data source, delegate and input handler for the grid. Owns the cell
    /// selection (display coordinates: visible row × on-screen column) and
    /// translates it to source rows / data columns for the edit buffer.
    @MainActor
    final class Coordinator: NSObject, NSTableViewDataSource, NSTableViewDelegate, EditableTableViewHandler {
        var page: RowsFetcher.Page
        var editBuffer: EditBuffer?
        var editVersion = 0
        var enums: [String: [String]] = [:]
        var schema: SchemaSnapshot = .empty
        var appliedHighlights: Set<EditBuffer.CellKey> = []
        var insertRowIndices: Set<Int> = []
        var deleteRowIndices: Set<Int> = []
        var sourceRowIndices: [Int] = []
        var pageGeneration: Int?
        var contentRevision = 0
        var viewState: TableTabViewState?
        var foreignKeyColumns: Set<String> = []
        var copyTarget: RowCopy.Target?
        var sortDirectionFor: ((String) -> TypedHeaderCell.SortDirection)?
        var onHeaderClick: ((String, TypedHeaderCell.SortDirection) -> Void)?
        var onFilterEqualsCell: ((Int, Int) -> Void)?
        var onFilterColumn: ((Int, ColumnFilterMode) -> Void)?
        var onShowColumnDistinct: ((String) -> Void)?
        var makeProfilerController: ((String) -> NSViewController?)?
        var onDeleteRows: (([Int]) -> Void)?
        var onDuplicateRows: (([Int]) -> Void)?
        var onAddRow: (() -> Void)?
        var onNavigateForeignKey: ((Int, Int) -> Void)?
        var onMessage: ((String, Bool) -> Void)?
        var columnLayoutKey: (UUID, String, String)?
        /// Retains the live profiler popover while it's shown.
        var profilerPopover: NSPopover?

        weak var tableView: EditableTableView?
        private(set) var selection = GridSelection()
        private var lastFocusRequestID: UUID?
        private var dragSelectsRows = false

        /// Display column → data column, in on-screen order (gutter excluded).
        private(set) var displayToData: [Int] = []
        private var dataToDisplay: [Int: Int] = [:]
        private var visibleBySource: [Int: Int] = [:]

        private enum RenderKind: Equatable { case value, placeholder, expression }
        private struct CachedRender {
            let value: String?
            let kind: RenderKind
            let rendered: CellFormat.Rendered
        }
        /// Rendering the attributed string was the dominant per-frame cost
        /// while scrolling. Entries remember the value they rendered, so a
        /// changed value is simply a miss — no invalidation bookkeeping.
        private var renderCache: [Int: CachedRender] = [:]

        static let gutterColumnID = "__pgbrain_row_index__"

        init(page: RowsFetcher.Page, editBuffer: EditBuffer?) {
            self.page = page
            self.editBuffer = editBuffer
        }

        // MARK: - Column / row mapping

        static func identifier(forDataCol i: Int, name: String) -> String { "\(i)_\(name)" }

        static func dataIndex(of column: NSTableColumn) -> Int? {
            let id = column.identifier.rawValue
            guard id != gutterColumnID, let underscore = id.firstIndex(of: "_") else { return nil }
            return Int(id[..<underscore])
        }

        func rebuildColumnMap() {
            displayToData = tableView?.tableColumns.compactMap(Self.dataIndex(of:)) ?? Array(page.columns.indices)
            dataToDisplay = Dictionary(uniqueKeysWithValues: displayToData.enumerated().map { ($1, $0) })
        }

        func rebuildSourceLookup() {
            visibleBySource = Dictionary(sourceRowIndices.enumerated().map { ($1, $0) }, uniquingKeysWith: { a, _ in a })
        }

        var rowCount: Int { page.rows.count }
        var colCount: Int { displayToData.count }

        func isGutter(tableColumn index: Int) -> Bool {
            guard let t = tableView, index >= 0, index < t.tableColumns.count else { return false }
            return t.tableColumns[index].identifier.rawValue == Self.gutterColumnID
        }

        func dataCol(forTableColumn index: Int) -> Int? {
            guard let t = tableView, index >= 0, index < t.tableColumns.count else { return nil }
            return Self.dataIndex(of: t.tableColumns[index])
        }

        func displayCol(forTableColumn index: Int) -> Int? {
            dataCol(forTableColumn: index).flatMap { dataToDisplay[$0] }
        }

        func tableColumnIndex(forDataCol dataCol: Int) -> Int? {
            tableView?.tableColumns.firstIndex { Self.dataIndex(of: $0) == dataCol }
        }

        func dataCol(forDisplayCol d: Int) -> Int? {
            d >= 0 && d < displayToData.count ? displayToData[d] : nil
        }

        func sourceIndex(forVisibleRow row: Int) -> Int {
            row >= 0 && row < sourceRowIndices.count ? sourceRowIndices[row] : row
        }

        func visibleRow(forSourceRow source: Int) -> Int? { visibleBySource[source] }

        func originalValue(visibleRow: Int, dataCol: Int) -> String? {
            guard visibleRow >= 0, visibleRow < page.rows.count else { return nil }
            let row = page.rows[visibleRow]
            return dataCol >= 0 && dataCol < row.count ? row[dataCol] : nil
        }

        /// What a cell holds for copying and previews: the staged value when
        /// there is one, NULL for a draft row's untouched cell, else the
        /// server value.
        func effectiveValue(visibleRow: Int, dataCol: Int) -> String? {
            let source = sourceIndex(forVisibleRow: visibleRow)
            if let entry = editBuffer?.entry(row: source, column: dataCol) { return entry.displayValue }
            if insertRowIndices.contains(source) { return nil }
            return originalValue(visibleRow: visibleRow, dataCol: dataCol)
        }

        // MARK: - Data source / delegate

        func numberOfRows(in tableView: NSTableView) -> Int { page.rows.count }

        func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
            guard let tableColumn else { return nil }
            let source = sourceIndex(forVisibleRow: row)
            if tableColumn.identifier.rawValue == Self.gutterColumnID {
                let cell = reuse(RowNumberCellView.self, id: "RowNumberCell", in: tableView)
                cell.configure(
                    rowNumber: page.offset + source + 1,
                    isFocused: selection.cursor?.row == row,
                    isInsert: insertRowIndices.contains(source)
                )
                return cell
            }
            guard let dataCol = Self.dataIndex(of: tableColumn), dataCol < page.columns.count else { return nil }
            let column = page.columns[dataCol]
            let (value, kind) = displayValue(visibleRow: row, source: source, dataCol: dataCol)
            let rendered = cachedRender(source: source, dataCol: dataCol, value: value, kind: kind, column: column)
            let displayCol = dataToDisplay[dataCol] ?? dataCol
            let here = GridSelection.Cell(row: row, col: displayCol)
            let cell = reuse(DataCellView.self, id: "DataCell", in: tableView)
            cell.configure(rendered: rendered, flags: DataCellView.Flags(
                isDirty: editBuffer?.isDirty(row: source, column: dataCol) ?? false,
                isRecentlyApplied: appliedHighlights.contains(EditBuffer.CellKey(row: source, column: dataCol)),
                isSelected: selection.contains(here) && !selection.isSingleCell,
                isCursor: selection.cursor == here
            ))
            return cell
        }

        private func displayValue(visibleRow: Int, source: Int, dataCol: Int) -> (String?, RenderKind) {
            if let entry = editBuffer?.entry(row: source, column: dataCol) {
                switch entry {
                case .literal(let v): return (v, .value)
                case .expression(let e): return (e, .expression)
                case .defaultKeyword: return ("DEFAULT", .expression)
                }
            }
            if insertRowIndices.contains(source) { return ("DEFAULT", .placeholder) }
            return (originalValue(visibleRow: visibleRow, dataCol: dataCol), .value)
        }

        private func cachedRender(source: Int, dataCol: Int, value: String?, kind: RenderKind, column: ColumnNode) -> CellFormat.Rendered {
            let key = (source << 16) | (dataCol & 0xFFFF)
            if let hit = renderCache[key], hit.value == value, hit.kind == kind { return hit.rendered }
            let rendered: CellFormat.Rendered
            switch kind {
            case .value: rendered = CellFormat.render(value: value, column: column)
            case .placeholder: rendered = CellFormat.renderPlaceholder(value ?? "", column: column)
            case .expression: rendered = CellFormat.renderExpression(value ?? "", column: column)
            }
            renderCache[key] = CachedRender(value: value, kind: kind, rendered: rendered)
            return rendered
        }

        func invalidateRenderCache() {
            renderCache.removeAll(keepingCapacity: true)
        }

        func tableView(_ tableView: NSTableView, rowViewForRow row: Int) -> NSTableRowView? {
            let source = sourceIndex(forVisibleRow: row)
            let v = reuse(HoverableRowView.self, id: "HoverRow", in: tableView)
            v.isInsertRow = insertRowIndices.contains(source)
            v.isDeleteRow = deleteRowIndices.contains(source)
            return v
        }

        private func reuse<V: NSView>(_ type: V.Type, id: String, in tableView: NSTableView) -> V {
            let identifier = NSUserInterfaceItemIdentifier(id)
            if let reused = tableView.makeView(withIdentifier: identifier, owner: self) as? V { return reused }
            let v = V()
            v.identifier = identifier
            return v
        }

        func tableView(_ tableView: NSTableView, didClick tableColumn: NSTableColumn) {
            guard let onHeaderClick, let dataCol = Self.dataIndex(of: tableColumn), dataCol < page.columns.count else { return }
            let name = page.columns[dataCol].name
            let next: TypedHeaderCell.SortDirection
            switch sortDirectionFor?(name) ?? .none {
            case .none:       next = .ascending
            case .ascending:  next = .descending
            case .descending: next = .none
            }
            onHeaderClick(name, next)
        }

        /// The gutter stays pinned on the left.
        func tableView(_ tableView: NSTableView, shouldReorderColumn columnIndex: Int, toColumn newColumnIndex: Int) -> Bool {
            !isGutter(tableColumn: columnIndex) && newColumnIndex > 0
        }

        @objc func columnDidMove(_ notification: Notification) {
            rebuildColumnMap()
            resetSelection()
            reloadVisibleRows()
        }

        @objc func columnDidResize(_ notification: Notification) {
            guard let col = notification.userInfo?["NSTableColumn"] as? NSTableColumn,
                  let key = columnLayoutKey,
                  let dataCol = Self.dataIndex(of: col), dataCol < page.columns.count
            else { return }
            ColumnLayoutStore.shared.setWidth(
                col.width,
                connectionID: key.0, schema: key.1, table: key.2,
                column: page.columns[dataCol].name
            )
        }

        @objc func editorFontDidChange() {
            invalidateRenderCache()
            if let t = tableView {
                t.rowHeight = DataGridView.gridRowHeight()
                t.reloadData()
            }
        }

        @objc func clipViewDidScroll(_ notification: Notification) {
            guard let clip = notification.object as? NSClipView, let viewState else { return }
            viewState.scrollOrigin = clip.bounds.origin
            viewState.anchorGeneration = pageGeneration
        }

        // MARK: - View state

        /// Put the scroll offset and cursor back when this tab's grid is
        /// re-mounted on the same page it was showing.
        func restoreViewState(in scroll: NSScrollView) {
            guard let viewState, let generation = pageGeneration,
                  viewState.anchorGeneration == generation else { return }
            if let cursor = viewState.cursor, cursor.row < rowCount, let d = dataToDisplay[cursor.col] {
                selection.select(GridSelection.Cell(row: cursor.row, col: d))
                syncRowSelection()
            }
            if let origin = viewState.scrollOrigin {
                DispatchQueue.main.async { [weak scroll] in
                    guard let scroll else { return }
                    scroll.contentView.scroll(to: origin)
                    scroll.reflectScrolledClipView(scroll.contentView)
                }
            }
        }

        private func rememberCursor() {
            guard let viewState else { return }
            viewState.cursor = selection.cursor.flatMap { c in
                dataCol(forDisplayCol: c.col).map { GridSelection.Cell(row: c.row, col: $0) }
            }
            viewState.anchorGeneration = pageGeneration
        }

        func markSeen(_ request: RowsLoader.FocusRequest?) {
            lastFocusRequestID = request?.id
        }

        func handle(_ request: RowsLoader.FocusRequest?) {
            guard let request, request.id != lastFocusRequestID else { return }
            lastFocusRequestID = request.id
            guard let row = visibleRow(forSourceRow: request.sourceRow),
                  let d = dataToDisplay[request.dataColumn] else { return }
            changeSelection { $0.select(GridSelection.Cell(row: row, col: d)) }
            if let t = tableView { t.window?.makeFirstResponder(t) }
            if request.beginEditing { gridBeginEditing(seed: nil) }
        }

        // MARK: - Selection

        func resetSelection() {
            selection.clear()
            syncRowSelection()
        }

        func clampSelection() {
            selection.clamp(rows: rowCount, cols: colCount)
        }

        /// Mutate the selection, repaint what changed, keep AppKit's row
        /// selection in step (it drives the soft row tint) and scroll the
        /// cursor into view.
        func changeSelection(scroll: Bool = true, _ body: (inout GridSelection) -> Void) {
            let before = selection
            body(&selection)
            guard selection != before, let t = tableView else { return }
            var rows = IndexSet(before.rows)
            rows.formUnion(IndexSet(selection.rows))
            let visible = t.rows(in: t.visibleRect)
            let visibleSet = IndexSet(integersIn: visible.location..<(visible.location + visible.length))
            let dirty = rows.intersection(visibleSet)
            if !dirty.isEmpty {
                t.reloadData(forRowIndexes: dirty, columnIndexes: IndexSet(integersIn: 0..<t.numberOfColumns))
            }
            syncRowSelection()
            if scroll, let cursor = selection.cursor, cursor.row < t.numberOfRows {
                t.scrollRowToVisible(cursor.row)
                if let d = dataCol(forDisplayCol: cursor.col), let tc = tableColumnIndex(forDataCol: d) {
                    t.scrollColumnToVisible(tc)
                }
            }
            rememberCursor()
        }

        func syncRowSelection() {
            guard let t = tableView else { return }
            let rows = IndexSet(selection.rows.filter { $0 < t.numberOfRows })
            if t.selectedRowIndexes != rows {
                t.selectRowIndexes(rows, byExtendingSelection: false)
            }
        }

        func reloadVisibleRows() {
            guard let t = tableView else { return }
            let visible = t.rows(in: t.visibleRect)
            guard visible.length > 0 else { return }
            t.reloadData(
                forRowIndexes: IndexSet(integersIn: visible.location..<(visible.location + visible.length)),
                columnIndexes: IndexSet(integersIn: 0..<t.numberOfColumns)
            )
        }

        private func reloadRows(sources: [Int]) {
            guard let t = tableView else { return }
            let rows = IndexSet(sources.compactMap { visibleRow(forSourceRow: $0) }.filter { $0 < t.numberOfRows })
            guard !rows.isEmpty else { return }
            t.reloadData(forRowIndexes: rows, columnIndexes: IndexSet(integersIn: 0..<t.numberOfColumns))
        }

        /// Visible rows the selection covers, or just `row` when it lies
        /// outside the selection (right-click on an unselected row).
        func targetRows(including row: Int? = nil) -> [Int] {
            if let row, !selection.rows.contains(row) { return [row] }
            return selection.rows
        }

        // MARK: - EditableTableViewHandler: pointer

        func gridMouseDown(row: Int, tableColumn: Int, modifiers: NSEvent.ModifierFlags, clickCount: Int) -> Bool {
            let shift = modifiers.contains(.shift)
            let cmd = modifiers.contains(.command)
            if isGutter(tableColumn: tableColumn) {
                dragSelectsRows = true
                changeSelection(scroll: false) { sel in
                    if shift, let a = sel.anchor { sel.selectRows(from: a.row, to: row, cols: colCount) }
                    else { sel.selectRows(from: row, to: row, cols: colCount, adding: cmd) }
                }
                return true
            }
            guard let d = displayCol(forTableColumn: tableColumn), let dataCol = dataCol(forDisplayCol: d) else { return false }
            dragSelectsRows = false
            let cell = GridSelection.Cell(row: row, col: d)
            if cmd, clickCount == 1 {
                if foreignKeyColumns.contains(page.columns[dataCol].name), let navigate = onNavigateForeignKey {
                    navigate(sourceIndex(forVisibleRow: row), dataCol)
                } else {
                    changeSelection(scroll: false) { $0.add(cell) }
                }
                return true
            }
            if shift {
                changeSelection(scroll: false) { $0.extend(to: cell) }
                return true
            }
            if clickCount >= 2 {
                changeSelection(scroll: false) { $0.select(cell) }
                presentEditor(visibleRow: row, dataCol: dataCol, seed: nil, fromKeyboard: false)
                return true
            }
            changeSelection(scroll: false) { $0.select(cell) }
            return true
        }

        func gridDrag(toRow row: Int, tableColumn: Int) {
            if dragSelectsRows {
                changeSelection { sel in
                    if let a = sel.anchor { sel.selectRows(from: a.row, to: row, cols: colCount) }
                }
                return
            }
            let d = displayCol(forTableColumn: tableColumn) ?? (isGutter(tableColumn: tableColumn) ? 0 : nil)
            guard let d else { return }
            changeSelection { $0.extend(to: GridSelection.Cell(row: row, col: d)) }
        }

        // MARK: - EditableTableViewHandler: keyboard

        func gridMove(rowDelta: Int, colDelta: Int, extend: Bool, wrap: Bool) {
            changeSelection { $0.move(rowDelta: rowDelta, colDelta: colDelta, rows: rowCount, cols: colCount, extend: extend, wrap: wrap) }
        }

        func gridJump(rowEdge: Int, colEdge: Int, extend: Bool) {
            guard rowCount > 0, colCount > 0 else { return }
            let current = selection.cursor ?? GridSelection.Cell(row: 0, col: 0)
            var target = current
            if rowEdge < 0 { target.row = 0 } else if rowEdge > 0 { target.row = rowCount - 1 }
            if colEdge < 0 { target.col = 0 } else if colEdge > 0 { target.col = colCount - 1 }
            changeSelection { extend ? $0.extend(to: target) : $0.select(target) }
        }

        func gridEscape() {
            guard let cursor = selection.cursor, !selection.isSingleCell else { return }
            changeSelection { $0.select(cursor) }
        }

        func gridSelectAll() {
            changeSelection(scroll: false) { $0.selectAll(rows: rowCount, cols: colCount) }
        }

        func gridBeginEditing(seed: String?) {
            guard let cursor = selection.cursor, let dataCol = dataCol(forDisplayCol: cursor.col) else { return }
            if editBuffer == nil {
                if seed == nil { onMessage?("This grid is read-only.", false) }
                return
            }
            presentEditor(visibleRow: cursor.row, dataCol: dataCol, seed: seed, fromKeyboard: true)
        }

        var gridHasSelection: Bool { !selection.isEmpty }

        // MARK: - Editing

        /// Kinds where a typed first character is a sensible start of the
        /// new value; pickers (bool, enum, temporal, JSON) open unseeded.
        private func acceptsSeed(_ column: ColumnNode) -> Bool {
            switch InputKind.resolve(typeName: column.typeName, enums: enums) {
            case .text, .integer, .decimal, .uuid, .bytes, .interval, .network, .array, .geometry, .unknown:
                return true
            case .boolean, .date, .time, .timestamp, .json, .enumType:
                return false
            }
        }

        func presentEditor(visibleRow: Int, dataCol: Int, seed: String?, fromKeyboard: Bool) {
            guard let buffer = editBuffer, let t = tableView,
                  visibleRow >= 0, visibleRow < rowCount, dataCol >= 0, dataCol < page.columns.count,
                  let tableCol = tableColumnIndex(forDataCol: dataCol)
            else { return }
            let source = sourceIndex(forVisibleRow: visibleRow)
            if deleteRowIndices.contains(source) {
                onMessage?("This row is staged for deletion — keep it first to edit.", false)
                return
            }
            let column = page.columns[dataCol]
            let isDraft = insertRowIndices.contains(source)
            var initial: TypedInputValue
            if let entry = buffer.entry(row: source, column: dataCol) {
                initial = entry.typed
            } else if isDraft {
                initial = .defaultKeyword
            } else {
                initial = TypedInputValue(serverValue: originalValue(visibleRow: visibleRow, dataCol: dataCol))
            }
            let seeded = seed != nil && acceptsSeed(column)
            if seeded, let seed { initial = .literal(seed) }
            t.scrollRowToVisible(visibleRow)
            t.scrollColumnToVisible(tableCol)
            let rect = t.frameOfCell(atColumn: tableCol, row: visibleRow)
            let cols = page.columns
            let schema = self.schema
            let completions: (String, String, Int) -> [CompletionItem] = { partial, _, _ in
                SQLCompletionProvider.items(for: partial, in: schema, context: .expression(columns: cols))
            }
            CellEditorPopover.show(
                for: column,
                initial: initial,
                enums: enums,
                completions: completions,
                relativeTo: rect,
                of: t,
                caretAtEnd: seeded,
                onClose: { [weak t] in
                    guard let t else { return }
                    t.window?.makeFirstResponder(t)
                }
            ) { [weak self] typed in
                guard let self else { return }
                self.commit(sourceRow: source, dataCol: dataCol, typed: typed)
                if fromKeyboard {
                    self.gridMove(rowDelta: 1, colDelta: 0, extend: false, wrap: false)
                }
            }
        }

        /// Stage a value. Editing a cell back to its server value un-stages
        /// it; on a draft row DEFAULT is the untouched state, while an
        /// explicit NULL is a real value to insert.
        func commit(sourceRow: Int, dataCol: Int, typed: TypedInputValue) {
            guard let buffer = editBuffer else { return }
            buffer.apply([change(sourceRow: sourceRow, dataCol: dataCol, typed: typed)])
            reloadRows(sources: [sourceRow])
        }

        private func change(sourceRow: Int, dataCol: Int, typed: TypedInputValue) -> EditBuffer.Change {
            let key = EditBuffer.CellKey(row: sourceRow, column: dataCol)
            if insertRowIndices.contains(sourceRow) {
                return EditBuffer.Change(key: key, state: typed == .defaultKeyword ? .clean : .staged(EditBuffer.Entry(typed)))
            }
            let original = visibleRow(forSourceRow: sourceRow).flatMap { originalValue(visibleRow: $0, dataCol: dataCol) }
            return EditBuffer.Change(key: key, state: typed.isNoOp(against: original) ? .clean : .staged(EditBuffer.Entry(typed)))
        }

        private func isTextColumn(_ column: ColumnNode) -> Bool {
            InputKind.resolve(typeName: column.typeName, enums: enums) == .text
        }

        /// Delete / Backspace / ⌃⌘N over the selection. NOT NULL text columns
        /// get an empty string; other NOT NULL columns are left alone and
        /// reported.
        func gridSetNull() {
            guard let buffer = editBuffer else { return }
            var changes: [EditBuffer.Change] = []
            var refused = Set<String>()
            for cell in selection.cells {
                guard let dataCol = dataCol(forDisplayCol: cell.col), dataCol < page.columns.count else { continue }
                let source = sourceIndex(forVisibleRow: cell.row)
                if deleteRowIndices.contains(source) { continue }
                let column = page.columns[dataCol]
                if column.nullable {
                    changes.append(change(sourceRow: source, dataCol: dataCol, typed: .null))
                } else if isTextColumn(column) {
                    changes.append(change(sourceRow: source, dataCol: dataCol, typed: .literal("")))
                } else {
                    refused.insert(column.name)
                }
            }
            buffer.apply(changes)
            reloadVisibleRows()
            if !refused.isEmpty {
                onMessage?("Left unchanged — NOT NULL: \(refused.sorted().joined(separator: ", "))", true)
            }
        }

        func gridDeleteRows() {
            guard let onDeleteRows, !selection.isEmpty else { return }
            onDeleteRows(selection.rows.map(sourceIndex(forVisibleRow:)))
        }

        // MARK: - Clipboard

        func selectionTSV() -> String? {
            guard !selection.isEmpty else { return nil }
            return GridClipboard.tsv(for: selection) { [self] cell in
                guard let dataCol = dataCol(forDisplayCol: cell.col) else { return nil }
                return effectiveValue(visibleRow: cell.row, dataCol: dataCol)
            }
        }

        func gridCopy() -> Bool {
            guard let tsv = selectionTSV() else { return false }
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(tsv, forType: .string)
            return true
        }

        var gridCanPaste: Bool {
            editBuffer != nil && !selection.isEmpty && NSPasteboard.general.string(forType: .string) != nil
        }

        func gridPaste() -> Bool {
            guard let buffer = editBuffer, !selection.isEmpty,
                  let text = NSPasteboard.general.string(forType: .string) else { return false }
            let plan = GridClipboard.plan(GridClipboard.parse(text), into: selection, rowCount: rowCount, colCount: colCount)
            var changes: [EditBuffer.Change] = []
            var refused = 0
            var skippedDeleted = 0
            for (cell, field) in plan.cells {
                guard let dataCol = dataCol(forDisplayCol: cell.col), dataCol < page.columns.count else { continue }
                let source = sourceIndex(forVisibleRow: cell.row)
                if deleteRowIndices.contains(source) { skippedDeleted += 1; continue }
                guard let typed = pastedValue(field, column: page.columns[dataCol]) else { refused += 1; continue }
                changes.append(change(sourceRow: source, dataCol: dataCol, typed: typed))
            }
            buffer.apply(changes)
            reloadVisibleRows()
            var notes: [String] = []
            if plan.clipped > 0 { notes.append("\(plan.clipped) value\(plan.clipped == 1 ? "" : "s") past the grid edge dropped") }
            if refused > 0 { notes.append("\(refused) empty value\(refused == 1 ? "" : "s") refused by NOT NULL") }
            if skippedDeleted > 0 { notes.append("\(skippedDeleted) cell\(skippedDeleted == 1 ? "" : "s") on rows staged for deletion skipped") }
            if !notes.isEmpty {
                onMessage?("Pasted \(changes.count) cell\(changes.count == 1 ? "" : "s") · " + notes.joined(separator: " · "), plan.clipped > 0 || refused > 0)
            }
            return true
        }

        /// Clipboard text → staged value. The configured NULL token and blank
        /// fields in non-text columns become NULL (a blank can't be an
        /// integer or a date); nil when NOT NULL forbids it.
        private func pastedValue(_ text: String, column: ColumnNode) -> TypedInputValue? {
            let token = GridClipboard.nullToken
            if !token.isEmpty, text == token { return column.nullable ? .null : nil }
            if text.isEmpty, !isTextColumn(column) { return column.nullable ? .null : nil }
            return .literal(text)
        }

        // MARK: - Undo / redo

        var gridCanUndo: Bool { editBuffer?.canUndo ?? false }
        var gridCanRedo: Bool { editBuffer?.canRedo ?? false }

        func gridUndo() -> Bool {
            guard let buffer = editBuffer, buffer.canUndo else { return false }
            reveal(buffer.undo())
            return true
        }

        func gridRedo() -> Bool {
            guard let buffer = editBuffer, buffer.canRedo else { return false }
            reveal(buffer.redo())
            return true
        }

        private func reveal(_ key: EditBuffer.CellKey?) {
            reloadVisibleRows()
            guard let key, let row = visibleRow(forSourceRow: key.row), let d = dataToDisplay[key.column] else { return }
            changeSelection { $0.select(GridSelection.Cell(row: row, col: d)) }
        }

        // MARK: - Hover preview

        func gridHoverPreview(row: Int, tableColumn: Int) -> String? {
            guard let dataCol = dataCol(forTableColumn: tableColumn), dataCol < page.columns.count,
                  let value = effectiveValue(visibleRow: row, dataCol: dataCol)
            else { return nil }
            switch ColumnTypeKind.from(typeName: page.columns[dataCol].typeName) {
            case .json:
                return JSONFormatter.pretty(value) ?? value
            case .text, .unknown:
                guard value.count > 60 || value.contains("\n") else { return nil }
                return value
            default:
                return nil
            }
        }
    }
}
