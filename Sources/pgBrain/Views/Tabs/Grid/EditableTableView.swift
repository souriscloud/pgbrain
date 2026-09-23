import AppKit

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
    /// ⌘⌫ — stage the selected row(s) for deletion. The closure resolves
    /// the current selection to source rows and calls the delete hook.
    var onDeleteSelectedRows: (() -> Void)?
    /// ⌃⌘N — stage an explicit NULL for the keyboard-focused cell.
    var onSetNull: (() -> Void)?
    /// `(visibleRow, dataCol) → preview text?`. The coordinator returns the
    /// full (pretty-printed for JSON) value when the cell is worth a hover
    /// popover, else nil. `dataCol` is 0-indexed over data columns.
    var hoverPreviewProvider: ((Int, Int) -> String?)?

    /// Hover-preview state. We arm a delayed `perform` on mouse-moved over a
    /// previewable cell and show an `NSPopover` with the full value; moving
    /// off the cell (or out of the table) cancels/closes it.
    private var hoverPopover: NSPopover?
    private var hoverRow: Int = -1
    private var hoverCol: Int = -1
    private var hoverTracking: NSTrackingArea?

    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        // A cell-editor popover is open — it (and its text field) owns
        // ⌘C / ⌘Z / typing. The popover is semitransient so this table's
        // window stays key; without standing down we'd grab ⌘C and copy
        // the whole row instead of the editor's selection.
        if CellEditorPopover.isPresenting {
            return super.performKeyEquivalent(with: event)
        }
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
        // ⌃⌘N → stage an explicit NULL for the focused cell.
        if cmd, event.modifierFlags.contains(.control), chars == "n" {
            onSetNull?()
            return true
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
        // ⌘⌫ — stage the selected row(s) for deletion (committed on Apply).
        if event.modifierFlags.contains(.command), event.keyCode == 51 {
            onDeleteSelectedRows?()
            return
        }
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

    // MARK: - Hover preview

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let existing = hoverTracking { removeTrackingArea(existing) }
        let area = NSTrackingArea(
            rect: bounds,
            options: [.mouseEnteredAndExited, .mouseMoved, .activeInActiveApp, .inVisibleRect],
            owner: self, userInfo: nil
        )
        addTrackingArea(area)
        hoverTracking = area
    }

    override func mouseMoved(with event: NSEvent) {
        super.mouseMoved(with: event)
        let point = convert(event.locationInWindow, from: nil)
        let row = self.row(at: point)
        let tableCol = self.column(at: point)
        let dataCol = tableCol - 1
        // Same cell as last move: leave the armed/visible popover alone.
        if row == hoverRow, dataCol == hoverCol { return }
        cancelHoverPreview()
        hoverRow = row
        hoverCol = dataCol
        guard row >= 0, dataCol >= 0 else { return }
        // Arm a delayed show so the popover only appears on a genuine hover,
        // not while the pointer sweeps across the grid.
        perform(#selector(showHoverPreview), with: nil, afterDelay: 0.6)
    }

    override func mouseExited(with event: NSEvent) {
        super.mouseExited(with: event)
        cancelHoverPreview()
        hoverRow = -1
        hoverCol = -1
    }

    private func cancelHoverPreview() {
        NSObject.cancelPreviousPerformRequests(withTarget: self, selector: #selector(showHoverPreview), object: nil)
        hoverPopover?.close()
        hoverPopover = nil
    }

    @objc private func showHoverPreview() {
        let row = hoverRow
        let dataCol = hoverCol
        guard row >= 0, dataCol >= 0,
              let text = hoverPreviewProvider?(row, dataCol), !text.isEmpty
        else { return }
        let rect = frameOfCell(atColumn: dataCol + 1, row: row)
        guard rect != .zero else { return }
        let popover = NSPopover()
        popover.behavior = .transient
        popover.animates = false
        popover.contentViewController = HoverPreviewController(text: text)
        hoverPopover = popover
        popover.show(relativeTo: rect, of: self, preferredEdge: .maxY)
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

/// Scrollable, monospaced read-only display for the cell hover preview.
/// Sized to the content up to a cap so a 4-line JSON blob shows compactly
/// while a large document scrolls inside a bounded popover.
final class HoverPreviewController: NSViewController {
    private let text: String

    init(text: String) {
        self.text = text
        super.init(nibName: nil, bundle: nil)
    }
    required init?(coder: NSCoder) { fatalError() }

    override func loadView() {
        let textView = NSTextView()
        textView.isEditable = false
        textView.isSelectable = true
        textView.drawsBackground = false
        textView.textContainerInset = NSSize(width: 4, height: 4)
        textView.font = .monospacedSystemFont(ofSize: CellFormat.baseSize, weight: .regular)
        textView.string = text
        textView.textColor = .labelColor

        // Measure the content so short previews don't open a giant box.
        let maxSize = NSSize(width: 520, height: 360)
        textView.textContainer?.containerSize = NSSize(width: maxSize.width - 8,
                                                       height: .greatestFiniteMagnitude)
        if let container = textView.textContainer {
            textView.layoutManager?.ensureLayout(for: container)
        }
        let used = (textView.textContainer.map { textView.layoutManager?.usedRect(for: $0).size } ?? nil) ?? maxSize
        let contentSize = NSSize(
            width: min(maxSize.width, max(160, used.width + 16)),
            height: min(maxSize.height, max(28, used.height + 16))
        )

        let scroll = NSScrollView(frame: NSRect(origin: .zero, size: contentSize))
        scroll.documentView = textView
        scroll.hasVerticalScroller = used.height + 16 > maxSize.height
        scroll.hasHorizontalScroller = false
        scroll.drawsBackground = false
        scroll.borderType = .noBorder
        textView.frame = NSRect(origin: .zero, size: NSSize(width: contentSize.width, height: max(contentSize.height, used.height + 16)))
        textView.minSize = NSSize(width: 0, height: 0)
        textView.maxSize = NSSize(width: contentSize.width, height: .greatestFiniteMagnitude)
        textView.isVerticallyResizable = true
        textView.isHorizontallyResizable = false
        textView.textContainer?.widthTracksTextView = true

        self.view = scroll
        preferredContentSize = contentSize
    }
}
