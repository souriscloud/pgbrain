import AppKit

/// Row view that paints subtle hover, row-selection, draft-insert and
/// staged-delete tints. The row selection mirrors the rows the cell
/// selection touches, so it's drawn softer than the selected cells.
final class HoverableRowView: NSTableRowView {
    private var isHovered = false {
        didSet { if oldValue != isHovered { needsDisplay = true } }
    }
    var isInsertRow = false {
        didSet { if oldValue != isInsertRow { needsDisplay = true } }
    }
    var isDeleteRow = false {
        didSet { if oldValue != isDeleteRow { needsDisplay = true } }
    }
    private var trackingArea: NSTrackingArea?

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        // `.inVisibleRect` areas follow bounds on their own; rebuilding one
        // on every recycle-driven layout pass made scrolling stutter.
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
            NSColor.controlAccentColor.withAlphaComponent(0.05).setFill()
            bounds.fill()
        }
    }

    override func drawSelection(in dirtyRect: NSRect) {
        guard isSelected else { return }
        NSColor.controlAccentColor.withAlphaComponent(0.06).setFill()
        bounds.fill()
        NSColor.controlAccentColor.withAlphaComponent(0.85).setFill()
        NSRect(x: 0, y: 0, width: 2, height: bounds.height).fill()
    }
}

/// Fixed-width leftmost column showing the 1-based row number (✦ for a
/// draft insert). Highlights when its row holds the cursor.
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
        NSColor.separatorColor.withAlphaComponent(0.06).setFill()
        bounds.fill()
        NSColor.separatorColor.withAlphaComponent(0.35).setFill()
        NSRect(x: bounds.maxX - 0.5, y: 0, width: 0.5, height: bounds.height).fill()
        if isFocused {
            Self.brand.withAlphaComponent(0.85).setFill()
            NSRect(x: bounds.maxX - 2, y: 0, width: 2, height: bounds.height).fill()
        }
        super.draw(dirtyRect)
    }

    static let brand = NSColor(red: 0.42, green: 0.32, blue: 0.86, alpha: 1)
}

/// Display-only data cell. Takes a pre-rendered attributed string from the
/// coordinator's render cache and paints the selection / cursor / dirty /
/// just-applied states around it.
final class DataCellView: NSTableCellView {
    struct Flags: Equatable {
        var isDirty = false
        var isRecentlyApplied = false
        var isSelected = false
        var isCursor = false
    }

    private let field = NSTextField(labelWithString: "")
    private var flags = Flags()
    /// Identity of the last attributed string assigned, so re-configuring
    /// with the same cached render skips NSTextField's layout invalidation.
    private var lastAttributedID: ObjectIdentifier?
    private var lastToolTip: String?

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        // Manual frame layout: AutoLayout per cell per scroll tick was the
        // dominant cost while scrolling.
        field.translatesAutoresizingMaskIntoConstraints = true
        field.autoresizingMask = []
        field.drawsBackground = false
        field.lineBreakMode = .byTruncatingTail
        // Not `usesSingleLineMode`: that flattens per-range attributes.
        field.cell?.isScrollable = true
        field.isSelectable = false
        addSubview(field)
        self.textField = field
    }

    required init?(coder: NSCoder) { fatalError() }

    override func layout() {
        super.layout()
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
        lastAttributedID = nil
        lastToolTip = nil
    }

    override func draw(_ dirtyRect: NSRect) {
        if flags == Flags() {
            super.draw(dirtyRect)
            return
        }
        if flags.isSelected {
            NSColor.controlAccentColor.withAlphaComponent(0.20).setFill()
            bounds.fill()
        }
        if flags.isDirty {
            NSColor.systemYellow.withAlphaComponent(0.12).setFill()
            bounds.fill()
        } else if flags.isRecentlyApplied {
            NSColor.systemGreen.withAlphaComponent(0.16).setFill()
            bounds.fill()
        }
        super.draw(dirtyRect)
        if flags.isDirty {
            NSColor.systemYellow.setFill()
            NSRect(x: 0, y: 0, width: 3, height: bounds.height).fill()
        } else if flags.isRecentlyApplied {
            NSColor.systemGreen.setFill()
            NSRect(x: 0, y: 0, width: 3, height: bounds.height).fill()
        }
        if flags.isCursor {
            let path = NSBezierPath(roundedRect: bounds.insetBy(dx: 1, dy: 1), xRadius: 3, yRadius: 3)
            path.lineWidth = 1.5
            RowNumberCellView.brand.withAlphaComponent(0.9).setStroke()
            path.stroke()
        }
    }

    func configure(rendered: CellFormat.Rendered, flags newFlags: Flags) {
        let stateChanged = flags != newFlags
        flags = newFlags

        let nextID = ObjectIdentifier(rendered.attributed)
        if lastAttributedID != nextID {
            field.attributedStringValue = rendered.attributed
            lastAttributedID = nextID
        }

        let nextToolTip: String? = (rendered.attributed.length > 32 || rendered.attributed.string.contains("\n"))
            ? rendered.rawForEditor : nil
        if lastToolTip != nextToolTip {
            toolTip = nextToolTip
            lastToolTip = nextToolTip
        }
        if stateChanged { needsDisplay = true }
    }
}
