import AppKit

/// What the grid's table view asks of its controller. Row indices are
/// visible rows; `tableColumn` is the on-screen column index (0 = gutter
/// unless the user dragged it, so the handler resolves it by identifier).
@MainActor
protocol EditableTableViewHandler: AnyObject {
    func gridCopy() -> Bool
    func gridPaste() -> Bool
    func gridSelectAll()
    func gridUndo() -> Bool
    func gridRedo() -> Bool
    var gridCanUndo: Bool { get }
    var gridCanRedo: Bool { get }
    var gridCanPaste: Bool { get }
    var gridHasSelection: Bool { get }
    /// Delete / Backspace / ⌃⌘N: stage NULL in the selected cells.
    func gridSetNull()
    /// ⌘⌫: stage the selected rows for deletion.
    func gridDeleteRows()
    func gridMove(rowDelta: Int, colDelta: Int, extend: Bool, wrap: Bool)
    /// ⌘-arrows: jump to the first / last row or column.
    func gridJump(rowEdge: Int, colEdge: Int, extend: Bool)
    /// Return / F2 (seed nil) or a typed character (seed = that text).
    func gridBeginEditing(seed: String?)
    func gridEscape()
    /// Returns false to let NSTableView handle the click itself.
    func gridMouseDown(row: Int, tableColumn: Int, modifiers: NSEvent.ModifierFlags, clickCount: Int) -> Bool
    func gridDrag(toRow row: Int, tableColumn: Int)
    func gridContextMenu(row: Int, tableColumn: Int) -> NSMenu?
    func gridHoverPreview(row: Int, tableColumn: Int) -> String?
}

/// NSTableView subclass that turns row-based AppKit input into
/// spreadsheet-style cell navigation, editing and clipboard handling, all
/// forwarded to an `EditableTableViewHandler`.
///
/// Key equivalents (⌘C, ⌘V, ⌘A, ⌘Z, ⌘⇧Z, ⌃⌘N) are only claimed while this
/// view is the first responder of the key window. Without that gate the
/// grid would answer ⌘C typed into the WHERE field, the find bar or a
/// cell-editor popover (a separate key window) by copying grid cells.
final class EditableTableView: NSTableView {
    weak var handler: EditableTableViewHandler?

    private var hoverPopover: NSPopover?
    private var hoverRow: Int = -1
    private var hoverCol: Int = -1
    private var hoverTracking: NSTrackingArea?

    /// True when keyboard input is actually aimed at this grid.
    var ownsKeyboardFocus: Bool {
        guard let window else { return false }
        return window.isKeyWindow && window.firstResponder === self
    }

    override var acceptsFirstResponder: Bool { true }

    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        guard ownsKeyboardFocus, let handler else { return super.performKeyEquivalent(with: event) }
        let flags = event.modifierFlags.intersection([.command, .shift, .option, .control])
        let chars = event.charactersIgnoringModifiers?.lowercased() ?? ""
        switch (flags, chars) {
        case ([.command], "c"):
            if handler.gridCopy() { return true }
        case ([.command], "v"):
            if handler.gridPaste() { return true }
        case ([.command], "a"):
            handler.gridSelectAll()
            return true
        case ([.command], "z"):
            if handler.gridUndo() { return true }
        case ([.command, .shift], "z"):
            if handler.gridRedo() { return true }
        case ([.command, .control], "n"):
            handler.gridSetNull()
            return true
        default:
            break
        }
        return super.performKeyEquivalent(with: event)
    }

    // Menu-driven equivalents (Edit ▸ Copy / Paste / Select All / Undo /
    // Redo) arrive here through the responder chain.
    @objc func copy(_ sender: Any?) { _ = handler?.gridCopy() }
    @objc func paste(_ sender: Any?) { _ = handler?.gridPaste() }
    override func selectAll(_ sender: Any?) { handler?.gridSelectAll() }
    @objc func undo(_ sender: Any?) { _ = handler?.gridUndo() }
    @objc func redo(_ sender: Any?) { _ = handler?.gridRedo() }

    override func validateUserInterfaceItem(_ item: NSValidatedUserInterfaceItem) -> Bool {
        guard let handler else { return super.validateUserInterfaceItem(item) }
        switch item.action {
        case #selector(copy(_:)): return handler.gridHasSelection
        case #selector(paste(_:)): return handler.gridCanPaste
        case #selector(undo(_:)): return handler.gridCanUndo
        case #selector(redo(_:)): return handler.gridCanRedo
        case #selector(selectAll(_:)): return true
        default: return super.validateUserInterfaceItem(item)
        }
    }

    override func keyDown(with event: NSEvent) {
        guard let handler else { return super.keyDown(with: event) }
        let flags = event.modifierFlags.intersection([.command, .shift, .option, .control])
        let shift = flags.contains(.shift)
        let cmd = flags.contains(.command)
        switch event.keyCode {
        case 123: cmd ? handler.gridJump(rowEdge: 0, colEdge: -1, extend: shift)
                      : handler.gridMove(rowDelta: 0, colDelta: -1, extend: shift, wrap: false); return
        case 124: cmd ? handler.gridJump(rowEdge: 0, colEdge: 1, extend: shift)
                      : handler.gridMove(rowDelta: 0, colDelta: 1, extend: shift, wrap: false); return
        case 125: cmd ? handler.gridJump(rowEdge: 1, colEdge: 0, extend: shift)
                      : handler.gridMove(rowDelta: 1, colDelta: 0, extend: shift, wrap: false); return
        case 126: cmd ? handler.gridJump(rowEdge: -1, colEdge: 0, extend: shift)
                      : handler.gridMove(rowDelta: -1, colDelta: 0, extend: shift, wrap: false); return
        case 48:  // Tab / ⇧Tab
            handler.gridMove(rowDelta: 0, colDelta: shift ? -1 : 1, extend: false, wrap: true); return
        case 36, 76:  // Return / Enter: edit; ⇧Return moves up
            if shift { handler.gridMove(rowDelta: -1, colDelta: 0, extend: false, wrap: false) }
            else if flags.isEmpty { handler.gridBeginEditing(seed: nil) }
            return
        case 120:  // F2
            handler.gridBeginEditing(seed: nil); return
        case 51, 117:  // Backspace / Forward Delete
            if cmd { handler.gridDeleteRows() } else if flags.isEmpty { handler.gridSetNull() }
            return
        case 53:
            handler.gridEscape(); return
        case 115:  // Home
            handler.gridJump(rowEdge: cmd ? -1 : 0, colEdge: -1, extend: shift); return
        case 119:  // End
            handler.gridJump(rowEdge: cmd ? 1 : 0, colEdge: 1, extend: shift); return
        default:
            break
        }
        if flags.subtracting(.shift).isEmpty, let chars = event.characters, Self.isPrintable(chars) {
            handler.gridBeginEditing(seed: chars)
            return
        }
        super.keyDown(with: event)
    }

    /// Text a keystroke would type — excludes control characters and the
    /// private-use range AppKit maps function / arrow keys into.
    static func isPrintable(_ s: String) -> Bool {
        guard !s.isEmpty else { return false }
        return s.unicodeScalars.allSatisfy { scalar in
            !CharacterSet.controlCharacters.contains(scalar)
                && !(0xF700...0xF8FF).contains(scalar.value)
        }
    }

    // MARK: - Mouse

    override func mouseDown(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        let row = self.row(at: point)
        let col = self.column(at: point)
        guard let handler, row >= 0, col >= 0 else { return super.mouseDown(with: event) }
        window?.makeFirstResponder(self)
        cancelHoverPreview()
        guard handler.gridMouseDown(row: row, tableColumn: col, modifiers: event.modifierFlags, clickCount: event.clickCount)
        else { return super.mouseDown(with: event) }
        if event.clickCount == 1, !event.modifierFlags.contains(.command) {
            trackDrag()
        }
    }

    /// Drag-select: extend the range until the button comes up, scrolling
    /// when the pointer leaves the visible area.
    private func trackDrag() {
        guard let window else { return }
        var lastRow = -1, lastCol = -1
        while let e = window.nextEvent(matching: [.leftMouseDragged, .leftMouseUp]) {
            if e.type == .leftMouseUp { break }
            autoscroll(with: e)
            let p = convert(e.locationInWindow, from: nil)
            let r = max(0, min(numberOfRows - 1, row(at: p) >= 0 ? row(at: p) : (p.y < visibleRect.midY ? 0 : numberOfRows - 1)))
            var c = column(at: p)
            if c < 0 { c = p.x < visibleRect.midX ? 0 : numberOfColumns - 1 }
            if r != lastRow || c != lastCol {
                handler?.gridDrag(toRow: r, tableColumn: c)
                lastRow = r; lastCol = c
            }
        }
    }

    override func menu(for event: NSEvent) -> NSMenu? {
        let point = convert(event.locationInWindow, from: nil)
        let row = self.row(at: point)
        let col = self.column(at: point)
        if row >= 0, col >= 0, let menu = handler?.gridContextMenu(row: row, tableColumn: col) {
            return menu
        }
        return super.menu(for: event)
    }

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
        let col = self.column(at: point)
        if row == hoverRow, col == hoverCol { return }
        cancelHoverPreview()
        hoverRow = row
        hoverCol = col
        guard row >= 0, col >= 0 else { return }
        // Delay so the popover only appears on a genuine hover, not while the
        // pointer sweeps across the grid.
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
        let col = hoverCol
        guard row >= 0, col >= 0, row < numberOfRows, col < numberOfColumns,
              let text = handler?.gridHoverPreview(row: row, tableColumn: col), !text.isEmpty
        else { return }
        let rect = frameOfCell(atColumn: col, row: row)
        guard rect != .zero else { return }
        let popover = NSPopover()
        popover.behavior = .transient
        popover.animates = false
        popover.contentViewController = HoverPreviewController(text: text)
        hoverPopover = popover
        popover.show(relativeTo: rect, of: self, preferredEdge: .maxY)
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
