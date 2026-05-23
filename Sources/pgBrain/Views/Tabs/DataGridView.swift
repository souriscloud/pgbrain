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

    @MainActor
    final class Coordinator: NSObject, NSTableViewDataSource, NSTableViewDelegate {
        var page: RowsFetcher.Page
        var editBuffer: EditBuffer?
        weak var tableView: NSTableView?
        // Observation token: bumps when EditBuffer mutates so we can refresh.
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
            cell.configure(
                value: effectiveValue(row: row, col: colIdx, original: original),
                column: column,
                isDirty: editBuffer?.isDirty(row: row, column: colIdx) ?? false,
                editable: editBuffer != nil
            )
            if editBuffer != nil {
                cell.onCommit = { [weak self] newValue in
                    self?.commit(row: row, col: colIdx, original: original, raw: newValue)
                }
            } else {
                cell.onCommit = nil
            }
            return cell
        }

        func tableView(_ tableView: NSTableView, heightOfRow row: Int) -> CGFloat { 20 }

        @objc func handleDoubleClick(_ sender: Any?) {
            guard editBuffer != nil, let table = tableView else { return }
            let row = table.clickedRow
            let col = table.clickedColumn
            guard row >= 0, col >= 0 else { return }
            table.editColumn(col, row: row, with: nil, select: true)
        }

        /// When the buffer has an edit for this cell, show the pending value;
        /// otherwise fall back to what the server returned.
        private func effectiveValue(row: Int, col: Int, original: String?) -> String? {
            guard let buffer = editBuffer, let pending = buffer.value(row: row, column: col).flatMap({ $0 }) else {
                return original
            }
            return pending
        }

        private func commit(row: Int, col: Int, original: String?, raw: String) {
            guard let buffer = editBuffer else { return }
            // Empty string from the editor is treated as "no change" when the
            // original cell was NULL — otherwise we'd silently overwrite NULL
            // with empty string on every focus-out. Setting NULL explicitly
            // gets its own affordance (deferred).
            if raw.isEmpty && original == nil { return }
            // Same as original → drop any pending edit instead of storing a
            // no-op (keeps the dirty count honest).
            if raw == (original ?? "") {
                // Only set if currently dirty, to record the revert in history.
                if buffer.isDirty(row: row, column: col) {
                    buffer.set(row: row, column: col, value: original)
                }
                return
            }
            buffer.set(row: row, column: col, value: raw)
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
        table.gridStyleMask = [.solidVerticalGridLineMask, .solidHorizontalGridLineMask]
        table.gridColor = NSColor.separatorColor.withAlphaComponent(0.5)
        table.allowsColumnReordering = true
        table.allowsColumnResizing = true
        table.columnAutoresizingStyle = .noColumnAutoresizing
        table.allowsMultipleSelection = false
        table.intercellSpacing = NSSize(width: 0, height: 0)
        table.rowSizeStyle = .custom
        table.style = .inset
        table.headerView = NSTableHeaderView()
        table.editBufferProvider = { [weak coord = context.coordinator] in coord?.editBuffer }

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
        context.coordinator.rebuildIndex()
        table.editBufferProvider = { [weak coord = context.coordinator] in coord?.editBuffer }
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
            column.title = col.name
            column.minWidth = 60
            column.width = estimatedWidth(for: col)
            column.maxWidth = 800
            column.isEditable = editable
            let kind = ColumnTypeKind.from(typeName: col.typeName)
            column.headerCell.alignment = headerAlignment(for: kind)
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
/// can undo pending edits without involving the system undo manager. We
/// intentionally don't fight NSUndoManager — there's no document to undo
/// against until Apply runs.
final class EditableTableView: NSTableView {
    var editBufferProvider: (() -> EditBuffer?)?

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
}

/// One reusable cell view that styles itself based on the column kind and
/// whether the host grid is editable. Editing uses a borderless text field
/// the table view promotes to first responder on double-click.
private final class DataCellView: NSTableCellView, NSTextFieldDelegate {
    private let field = EditingTextField()
    private let dirtyMark = DirtyTriangleView()
    private var currentKind: ColumnTypeKind = .unknown
    private var currentValueIsNull = false
    private var lastConfiguredText: String = ""
    private var isCancelling = false
    var onCommit: ((String) -> Void)?

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        field.translatesAutoresizingMaskIntoConstraints = false
        field.isBordered = false
        field.isBezeled = false
        field.drawsBackground = false
        field.focusRingType = .none
        field.lineBreakMode = .byTruncatingTail
        field.cell?.usesSingleLineMode = true
        field.cell?.isScrollable = true
        field.delegate = self
        addSubview(field)

        dirtyMark.translatesAutoresizingMaskIntoConstraints = false
        dirtyMark.isHidden = true
        addSubview(dirtyMark)

        NSLayoutConstraint.activate([
            field.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 6),
            field.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -6),
            field.centerYAnchor.constraint(equalTo: centerYAnchor),
            dirtyMark.topAnchor.constraint(equalTo: topAnchor),
            dirtyMark.trailingAnchor.constraint(equalTo: trailingAnchor),
            dirtyMark.widthAnchor.constraint(equalToConstant: 8),
            dirtyMark.heightAnchor.constraint(equalToConstant: 8),
        ])
        self.textField = field
    }

    required init?(coder: NSCoder) { fatalError() }

    override func draw(_ dirtyRect: NSRect) {
        if dirtyMark.isHidden == false {
            // Subtle tint behind dirty cells so the change reads even when
            // the column is wide and the triangle sits off-screen.
            NSColor.systemYellow.withAlphaComponent(0.08).setFill()
            dirtyRect.fill()
        }
        super.draw(dirtyRect)
    }

    func configure(value: String?, column: ColumnNode, isDirty: Bool, editable: Bool) {
        currentKind = ColumnTypeKind.from(typeName: column.typeName)
        currentValueIsNull = (value == nil)
        field.isEditable = editable
        field.isSelectable = editable
        dirtyMark.isHidden = !isDirty
        needsDisplay = true

        if value == nil {
            field.stringValue = ""
            field.placeholderString = "NULL"
            field.font = NSFont.systemFont(ofSize: 12).italic()
            field.textColor = .tertiaryLabelColor
            field.alignment = .left
            lastConfiguredText = ""
            return
        }
        field.placeholderString = nil
        let v = value ?? ""
        field.alignment = alignment(for: currentKind)
        field.font = font(for: currentKind)
        field.textColor = .labelColor
        let rendered: String
        switch currentKind {
        case .json:
            rendered = v
                .replacingOccurrences(of: "\n", with: " ")
                .replacingOccurrences(of: "  ", with: " ")
        case .bool:
            // Show the glyph in the read-only view; the editor swaps to the
            // raw value when editing begins (see `controlTextDidBeginEditing`).
            rendered = boolGlyph(for: v)
        default:
            rendered = v
        }
        field.stringValue = rendered
        lastConfiguredText = rendered
    }

    func controlTextDidBeginEditing(_ notif: Notification) {
        // For booleans we render a glyph; restore the raw token so the user
        // can edit (and the new value is something the server can parse).
        if currentKind == .bool {
            switch field.stringValue {
            case "✓": field.stringValue = "true"
            case "":  field.stringValue = "false"
            default: break
            }
        }
        // Restore label colour so the editor isn't a tertiary-grey text field.
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

/// 8×8 yellow triangle drawn in the top-right corner of a dirty cell.
private final class DirtyTriangleView: NSView {
    override var isFlipped: Bool { true }

    override func draw(_ dirtyRect: NSRect) {
        let path = NSBezierPath()
        path.move(to: NSPoint(x: bounds.width, y: 0))
        path.line(to: NSPoint(x: 0, y: 0))
        path.line(to: NSPoint(x: bounds.width, y: bounds.height))
        path.close()
        NSColor.systemYellow.setFill()
        path.fill()
    }
}

private extension NSFont {
    func italic() -> NSFont {
        let descriptor = fontDescriptor.withSymbolicTraits(.italic)
        return NSFont(descriptor: descriptor, size: pointSize) ?? self
    }
}
