import AppKit

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
    weak var coordinator: DataGridView.Coordinator?

    override var intrinsicContentSize: NSSize {
        NSSize(width: NSView.noIntrinsicMetric, height: 36)
    }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        self.frame = NSRect(origin: frameRect.origin,
                            size: NSSize(width: frameRect.width, height: 36))
    }
    required init?(coder: NSCoder) { fatalError() }

    /// Right-click on a column header → column-level menu (profile, distinct,
    /// copy name, filter null). The body's `menu(for:)` never fires over the
    /// header, so the header has to provide its own.
    override func menu(for event: NSEvent) -> NSMenu? {
        let point = convert(event.locationInWindow, from: nil)
        let tableCol = column(at: point)
        // Column 0 is the synthetic row-number gutter; data columns follow.
        let dataCol = tableCol - 1
        if dataCol >= 0, let menu = coordinator?.columnHeaderMenu(forDataCol: dataCol) {
            return menu
        }
        return super.menu(for: event)
    }
}
