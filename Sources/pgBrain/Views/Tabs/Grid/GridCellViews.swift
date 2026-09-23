import AppKit

/// Row view that paints subtle hover + selection tints. NSTableView's
/// built-in `.inset` selection is a loud solid-blue bar (very
/// pre-modern); we run with `selectionHighlightStyle = .none` and
/// draw both states ourselves with soft accent washes that read well
/// in light and dark mode alike.
final class HoverableRowView: NSTableRowView {
    private var isHovered = false {
        didSet { if oldValue != isHovered { needsDisplay = true } }
    }
    /// Draft INSERT row — painted with a soft green wash until committed.
    var isInsertRow = false {
        didSet { if oldValue != isInsertRow { needsDisplay = true } }
    }
    /// Row staged for DELETE — painted with a soft red wash until committed.
    var isDeleteRow = false {
        didSet { if oldValue != isDeleteRow { needsDisplay = true } }
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
        isInsertRow = false
        isDeleteRow = false
    }

    override func drawBackground(in dirtyRect: NSRect) {
        super.drawBackground(in: dirtyRect)
        if isInsertRow {
            NSColor.systemGreen.withAlphaComponent(0.10).setFill()
            bounds.fill()
        }
        if isDeleteRow {
            NSColor.systemRed.withAlphaComponent(0.14).setFill()
            bounds.fill()
        }
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

    func configure(rowNumber: Int, isFocused: Bool, isInsert: Bool = false) {
        if isInsert {
            label.stringValue = "✦"
            label.textColor = .systemGreen
        } else {
            label.stringValue = String(rowNumber)
            label.textColor = isFocused ? .labelColor : .tertiaryLabelColor
        }
        self.isFocused = isFocused
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
final class DataCellView: NSTableCellView, NSTextFieldDelegate {
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
        let h = NSFont.systemFont(ofSize: CellFormat.baseSize).boundingRectForFont.height + 2
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
final class EditingTextField: NSTextField {
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
