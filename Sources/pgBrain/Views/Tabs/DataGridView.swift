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
struct DataGridView: NSViewRepresentable {
    let page: RowsFetcher.Page
    /// Pass nil to render the grid read-only (e.g. for SQL scratchpad
    /// result blocks). Pass an `EditBuffer` to enable cell editing.
    var editBuffer: EditBuffer? = nil
    /// `(row, column)` cells that were just successfully applied. Cell
    /// rendering paints them with a fading green tint for a few seconds
    /// so the user can see exactly what landed.
    var appliedHighlights: Set<EditBuffer.CellKey> = []

    @MainActor
    final class Coordinator: NSObject, NSTableViewDataSource, NSTableViewDelegate {
        var page: RowsFetcher.Page
        var editBuffer: EditBuffer?
        var appliedHighlights: Set<EditBuffer.CellKey> = []
        weak var tableView: NSTableView?
        @ObservationIgnored var observationTask: Task<Void, Never>?

        init(page: RowsFetcher.Page, editBuffer: EditBuffer?) {
            self.page = page
            self.editBuffer = editBuffer
        }

        // Map column identifier → index for O(1) row lookup.
        private var indexByID: [String: Int] = [:]

        func rebuildIndex() {
            indexByID.removeAll(keepingCapacity: true)
            for (i, c) in page.columns.enumerated() {
                indexByID["\(i)_\(c.name)"] = i
            }
        }

        func numberOfRows(in tableView: NSTableView) -> Int { page.rows.count }

        func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
            guard let columnID = tableColumn?.identifier.rawValue,
                  let colIdx = indexByID[columnID] else { return nil }
            let column = page.columns[colIdx]
            let original = page.rows[row][colIdx]
            let cell = reuseCell(in: tableView)
            let isApplied = appliedHighlights.contains(EditBuffer.CellKey(row: row, column: colIdx))
            cell.configure(
                value: effectiveValue(row: row, col: colIdx, original: original),
                column: column,
                isDirty: editBuffer?.isDirty(row: row, column: colIdx) ?? false,
                isRecentlyApplied: isApplied,
                editable: editBuffer != nil
            )
            // Inline edit removed; popover is the only edit path.
            cell.onCommit = nil
            return cell
        }

        func tableView(_ tableView: NSTableView, heightOfRow row: Int) -> CGFloat { 22 }

        @objc func handleDoubleClick(_ sender: Any?) {
            guard let buffer = editBuffer, let table = tableView else { return }
            let row = table.clickedRow
            let col = table.clickedColumn
            guard row >= 0, col >= 0 else { return }
            presentEditor(row: row, col: col, in: table, buffer: buffer)
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
        /// pointer. Copy works in both editable and read-only mode; Set
        /// NULL / Edit only when the grid is editable.
        func contextMenu(forRow row: Int, col: Int) -> NSMenu? {
            guard row >= 0, col >= 0, col < page.columns.count, row < page.rows.count else { return nil }
            let column = page.columns[col]
            let original = page.rows[row][col]
            let displayed: String? = editBuffer?.value(row: row, column: col).flatMap { $0 } ?? original

            let menu = NSMenu()
            let copy = NSMenuItem(title: "Copy value", action: #selector(handleCopy(_:)), keyEquivalent: "")
            copy.target = self
            copy.representedObject = displayed ?? ""
            menu.addItem(copy)

            let copyName = NSMenuItem(title: "Copy column name", action: #selector(handleCopy(_:)), keyEquivalent: "")
            copyName.target = self
            copyName.representedObject = column.name
            menu.addItem(copyName)

            if editBuffer != nil {
                menu.addItem(.separator())
                let edit = NSMenuItem(title: "Edit…", action: #selector(handleEditMenu(_:)), keyEquivalent: "")
                edit.target = self
                edit.representedObject = CellLocator(row: row, col: col)
                menu.addItem(edit)
                if column.nullable {
                    let setNull = NSMenuItem(title: "Set NULL", action: #selector(handleSetNull(_:)), keyEquivalent: "")
                    setNull.target = self
                    setNull.representedObject = CellLocator(row: row, col: col)
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
                  let buffer = editBuffer else { return }
            let original = page.rows[loc.row][loc.col]
            commit(row: loc.row, col: loc.col, original: original, newValue: nil)
            tableView?.reloadData()
        }

        /// When the buffer has a pending edit for this cell, show it (which
        /// may be `nil` for an explicit Set NULL). Otherwise fall back to
        /// the server value. The earlier implementation used
        /// `flatMap({ $0 })` on a `String??`, which collapses
        /// `.some(.none)` (Set NULL) back to `.none` and made the cell
        /// silently keep showing the old value until Apply landed.
        private func effectiveValue(row: Int, col: Int, original: String?) -> String? {
            guard let buffer = editBuffer else { return original }
            // `buffer.value` returns String??: outer .some/.none = is-dirty,
            // inner .some/.none = the pending value (.none meaning NULL).
            if case .some(let pending) = buffer.value(row: row, column: col) {
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
                    reloadRow(row)
                }
                return
            }
            buffer.set(row: row, column: col, value: newValue)
            // SwiftUI's @Observable chain will eventually re-render the
            // table, but on same-key re-edits the observable signals can
            // coalesce and the cell is left displaying its previous text
            // for a beat. Force the affected row to refresh now so the
            // pending value (and dirty rail) are visible the instant the
            // popover closes — before any Apply.
            reloadRow(row)
        }

        private func reloadRow(_ row: Int) {
            guard let table = tableView, row >= 0, row < table.numberOfRows else { return }
            let cols = IndexSet(integersIn: 0..<table.numberOfColumns)
            table.reloadData(forRowIndexes: IndexSet(integer: row), columnIndexes: cols)
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
    }

    func makeCoordinator() -> Coordinator {
        Coordinator(page: page, editBuffer: editBuffer)
    }

    func makeNSView(context: Context) -> NSScrollView {
        let table = EditableTableView()
        table.usesAlternatingRowBackgroundColors = true
        table.gridStyleMask = [.solidHorizontalGridLineMask]
        table.gridColor = NSColor.separatorColor.withAlphaComponent(0.25)
        table.allowsColumnReordering = true
        table.allowsColumnResizing = true
        table.columnAutoresizingStyle = .noColumnAutoresizing
        table.allowsMultipleSelection = true
        // Small horizontal gap so column boundaries read as boundaries
        // instead of letting cells touch and look like one mash.
        table.intercellSpacing = NSSize(width: 6, height: 0)
        table.rowSizeStyle = .custom
        table.style = .inset
        table.headerView = TypedHeaderView()
        table.editBufferProvider = { [weak coord = context.coordinator] in coord?.editBuffer }
        table.contextMenuProvider = { [weak coord = context.coordinator] row, col in
            coord?.contextMenu(forRow: row, col: col)
        }

        applyColumns(to: table, coordinator: context.coordinator)
        table.dataSource = context.coordinator
        table.delegate = context.coordinator
        table.target = context.coordinator
        table.doubleAction = #selector(Coordinator.handleDoubleClick(_:))
        context.coordinator.rebuildIndex()
        context.coordinator.tableView = table

        let scroll = NSScrollView()
        scroll.documentView = table
        scroll.hasVerticalScroller = true
        scroll.hasHorizontalScroller = true
        scroll.borderType = .noBorder
        scroll.drawsBackground = false
        return scroll
    }

    func updateNSView(_ scroll: NSScrollView, context: Context) {
        guard let table = scroll.documentView as? EditableTableView else { return }
        let identityChanged = !columnsMatch(coordinator: context.coordinator, new: page.columns)
        let editableChanged = (context.coordinator.editBuffer != nil) != (editBuffer != nil)
        context.coordinator.page = page
        context.coordinator.editBuffer = editBuffer
        context.coordinator.appliedHighlights = appliedHighlights
        context.coordinator.rebuildIndex()
        table.editBufferProvider = { [weak coord = context.coordinator] in coord?.editBuffer }
        table.contextMenuProvider = { [weak coord = context.coordinator] row, col in
            coord?.contextMenu(forRow: row, col: col)
        }
        if identityChanged || editableChanged {
            // Remove all columns and re-add — happens on tab swap or when
            // the editability of the grid flips.
            for col in table.tableColumns { table.removeTableColumn(col) }
            applyColumns(to: table, coordinator: context.coordinator)
        }
        table.reloadData()
    }

    private func columnsMatch(coordinator: Coordinator, new: [ColumnNode]) -> Bool {
        guard coordinator.page.columns.count == new.count else { return false }
        return zip(coordinator.page.columns, new).allSatisfy { $0.name == $1.name && $0.typeName == $1.typeName }
    }

    private func applyColumns(to table: NSTableView, coordinator: Coordinator) {
        let editable = coordinator.editBuffer != nil
        for (i, col) in page.columns.enumerated() {
            let identifier = NSUserInterfaceItemIdentifier("\(i)_\(col.name)")
            let column = NSTableColumn(identifier: identifier)
            column.minWidth = 60
            column.width = estimatedWidth(for: col)
            column.maxWidth = 800
            column.isEditable = editable
            let kind = ColumnTypeKind.from(typeName: col.typeName)
            // Custom header cell: column name on top, PG type as small
            // uppercase tag underneath. Far more scannable than a single
            // title row when you have 15+ columns.
            column.headerCell = TypedHeaderCell(
                title: col.name,
                typeLabel: col.typeName,
                alignment: headerAlignment(for: kind)
            )
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

    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        let isCmdZ = event.modifierFlags.contains(.command)
            && !event.modifierFlags.contains(.shift)
            && (event.charactersIgnoringModifiers ?? "") == "z"
        if isCmdZ, let buffer = editBufferProvider?(), buffer.canUndo {
            _ = buffer.undo()
            reloadData()
            return true
        }
        return super.performKeyEquivalent(with: event)
    }

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
    var onCommit: ((String) -> Void)?

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        field.translatesAutoresizingMaskIntoConstraints = false
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

        NSLayoutConstraint.activate([
            // Left-padding leaves room for the dirty/applied rail.
            field.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 8),
            field.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -6),
            field.centerYAnchor.constraint(equalTo: centerYAnchor),
        ])
        self.textField = field
    }

    required init?(coder: NSCoder) { fatalError() }

    override func draw(_ dirtyRect: NSRect) {
        // Background tints first (use `bounds`, not the dirtyRect — the
        // dirtyRect is whatever AppKit happens to be invalidating and
        // gives a partial fill on scroll/refresh).
        if isDirty {
            NSColor.systemYellow.withAlphaComponent(0.10).setFill()
            bounds.fill()
        } else if isRecentlyApplied {
            NSColor.systemGreen.withAlphaComponent(0.16).setFill()
            bounds.fill()
        }
        super.draw(dirtyRect)
        // Then the left rail on top so it reads cleanly.
        if isDirty {
            NSColor.systemYellow.setFill()
            NSRect(x: 0, y: 0, width: 3, height: bounds.height).fill()
        } else if isRecentlyApplied {
            NSColor.systemGreen.setFill()
            NSRect(x: 0, y: 0, width: 3, height: bounds.height).fill()
        }
    }

    private var rawForEditor: String = ""

    func configure(value: String?, column: ColumnNode, isDirty: Bool, isRecentlyApplied: Bool, editable: Bool) {
        currentKind = ColumnTypeKind.from(typeName: column.typeName)
        currentValueIsNull = (value == nil)
        // Inline editing disabled — popover handles all edits. Cell stays
        // selectable so users can ⌘C the displayed text.
        field.isEditable = false
        field.isSelectable = true
        self.isDirty = isDirty
        self.isRecentlyApplied = isRecentlyApplied
        needsDisplay = true

        // Bake alignment into a paragraph style attached to the whole
        // string so we don't have to also set `field.alignment` (which can
        // override the attributed string in subtle ways).
        let rendered = CellFormat.render(value: value, column: column)
        let mutable = NSMutableAttributedString(attributedString: rendered.attributed)
        let para = NSMutableParagraphStyle()
        para.alignment = rendered.alignment
        para.lineBreakMode = .byTruncatingTail
        mutable.addAttribute(.paragraphStyle, value: para,
                             range: NSRange(location: 0, length: mutable.length))
        field.placeholderString = nil
        field.attributedStringValue = mutable
        lastConfiguredText = mutable.string
        rawForEditor = rendered.rawForEditor
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
final class TypedHeaderCell: NSTableHeaderCell {
    init(title: String, typeLabel: String, alignment: NSTextAlignment) {
        super.init(textCell: "")
        self.alignment = alignment
        let attr = NSMutableAttributedString()
        let nameAttrs: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: 12, weight: .semibold),
            .foregroundColor: NSColor.labelColor,
        ]
        let typeAttrs: [NSAttributedString.Key: Any] = [
            .font: NSFont.monospacedSystemFont(ofSize: 9, weight: .medium),
            .foregroundColor: NSColor.tertiaryLabelColor,
            .kern: NSNumber(value: 0.4),
        ]
        attr.append(NSAttributedString(string: title, attributes: nameAttrs))
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

/// Header view sized for two-line cells (column name + type tag).
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
