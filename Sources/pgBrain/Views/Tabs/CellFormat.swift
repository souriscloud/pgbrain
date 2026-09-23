import AppKit
import Foundation

/// Renders a `(value, column)` pair into an attributed string + display
/// hints (alignment, font) suited to the column's PG type. Plus a "raw"
/// path the inline editor uses when the user starts typing — that one
/// returns the unformatted string so the user types the value, not the
/// display.
///
/// Centralised here so the cell view stays a thin presenter and so future
/// types (arrays, hstore, time zones) only need a switch arm here.
@MainActor
enum CellFormat {
    struct Rendered {
        let attributed: NSAttributedString
        let alignment: NSTextAlignment
        let font: NSFont
        /// Plain text the inline editor should show when this cell goes
        /// into edit mode (so the user types the raw value the server
        /// will receive, not the formatted display).
        let rawForEditor: String
    }

    static func render(value: String?, column: ColumnNode) -> Rendered {
        let kind = ColumnTypeKind.from(typeName: column.typeName)
        let raw: Rendered
        if let v = value {
            switch kind {
            case .integer:           raw = integer(v, kind: kind)
            case .number:            raw = number(v, kind: kind)
            case .bool:              raw = boolean(v)
            case .date:              raw = dateOnly(v)
            case .timestamp:         raw = timestamp(v)
            case .json:              raw = json(v)
            case .uuid:              raw = uuid(v)
            case .bytes:             raw = bytes(v)
            case .text, .unknown:    raw = text(v, kind: kind)
            }
        } else {
            raw = Rendered(
                attributed: nullString(),
                alignment: alignment(for: kind),
                font: italicFont(),
                rawForEditor: ""
            )
        }
        // Bake the paragraph style into the attributed string once,
        // here at render time. The data grid caches the result so
        // every cell-recycle on scroll skips this work entirely.
        return Self.withParagraphStyle(raw)
    }

    /// Wrap `r.attributed` with a paragraph style carrying its
    /// alignment + truncation rule, returning a Rendered that the
    /// grid can hand straight to `field.attributedStringValue`.
    private static func withParagraphStyle(_ r: Rendered) -> Rendered {
        let mutable = NSMutableAttributedString(attributedString: r.attributed)
        let para = NSMutableParagraphStyle()
        para.alignment = r.alignment
        para.lineBreakMode = .byTruncatingTail
        if mutable.length > 0 {
            mutable.addAttribute(.paragraphStyle, value: para,
                                 range: NSRange(location: 0, length: mutable.length))
        }
        return Rendered(
            attributed: mutable,
            alignment: r.alignment,
            font: r.font,
            rawForEditor: r.rawForEditor
        )
    }

    // MARK: - Per-kind renderers

    /// The grid scales with the same setting as the SQL editor, so ⌘+ / ⌘−
    /// zoom the whole app. Computed (not cached) so a font change is picked
    /// up on the next render pass — the grid invalidates its render cache on
    /// `.pgbrainEditorFontChanged`.
    static var baseSize: CGFloat { CGFloat(AppSettings.shared.editorFontSize) }
    private static var mono: NSFont { .monospacedDigitSystemFont(ofSize: baseSize, weight: .regular) }
    private static var monoText: NSFont { .monospacedSystemFont(ofSize: baseSize, weight: .regular) }
    private static var body: NSFont { .systemFont(ofSize: baseSize) }

    /// Numbers are shown exactly as the server sent them, like psql: no
    /// grouping (ids read as 6000, not 6,000) and no round-trip through
    /// Double, which dropped a numeric's scale (14.50 → 14.5) and precision.
    private static func integer(_ raw: String, kind: ColumnTypeKind) -> Rendered {
        let formatted = raw.trimmingCharacters(in: .whitespaces)
        return Rendered(
            attributed: plain(formatted, color: .labelColor, font: mono),
            alignment: .right,
            font: mono,
            rawForEditor: raw
        )
    }

    private static func number(_ raw: String, kind: ColumnTypeKind) -> Rendered {
        let formatted = raw.trimmingCharacters(in: .whitespaces)
        return Rendered(
            attributed: plain(formatted, color: .labelColor, font: mono),
            alignment: .right,
            font: mono,
            rawForEditor: raw
        )
    }

    private static func boolean(_ raw: String) -> Rendered {
        // Unicode glyphs render reliably in NSTextField; NSTextAttachment-
        // based SF symbols don't (they get flattened or skipped).
        let truthy: Bool? = {
            switch raw.lowercased() {
            case "t", "true", "1", "yes", "y", "on": return true
            case "f", "false", "0", "no", "n", "off": return false
            default: return nil
            }
        }()
        let glyph: String
        let color: NSColor
        switch truthy {
        case .some(true):  glyph = "✓"; color = .systemGreen
        case .some(false): glyph = "·"; color = .tertiaryLabelColor
        case .none:        glyph = raw; color = .secondaryLabelColor
        }
        let font = NSFont.systemFont(ofSize: baseSize + 2, weight: .semibold)
        return Rendered(
            attributed: plain(glyph, color: color, font: font),
            alignment: .center,
            font: font,
            rawForEditor: raw
        )
    }

    /// Dates and timestamps show the server's own text: re-parsing into a
    /// `Date` would drop microseconds and shift zoned values into the Mac's
    /// zone, so the grid would disagree with what an edit sends back.
    private static func dateOnly(_ raw: String) -> Rendered {
        Rendered(
            attributed: plain(raw, color: .labelColor, font: mono),
            alignment: .left,
            font: mono,
            rawForEditor: raw
        )
    }

    private static func timestamp(_ raw: String) -> Rendered {
        Rendered(
            attributed: plain(raw, color: .labelColor, font: mono),
            alignment: .left,
            font: mono,
            rawForEditor: raw
        )
    }

    private static func json(_ raw: String) -> Rendered {
        // Collapse whitespace into a single-line preview. If it parses as
        // JSON, prettify the top-level structure subtly. Otherwise just
        // render the trimmed text.
        let collapsed = raw
            .components(separatedBy: .whitespacesAndNewlines)
            .filter { !$0.isEmpty }
            .joined(separator: " ")
        let attr = NSMutableAttributedString(string: collapsed, attributes: [
            .font: monoText,
            .foregroundColor: NSColor.labelColor,
        ])
        // Dim braces/brackets so structure pops a little. Cheap, no parse.
        for (i, ch) in collapsed.enumerated() {
            if "{}[]".contains(ch) {
                attr.addAttribute(
                    .foregroundColor,
                    value: NSColor.tertiaryLabelColor,
                    range: NSRange(location: i, length: 1)
                )
            }
        }
        return Rendered(
            attributed: attr,
            alignment: .left,
            font: monoText,
            rawForEditor: raw
        )
    }

    private static func uuid(_ raw: String) -> Rendered {
        Rendered(
            attributed: plain(raw, color: .secondaryLabelColor, font: monoText),
            alignment: .left,
            font: monoText,
            rawForEditor: raw
        )
    }

    private static func bytes(_ raw: String) -> Rendered {
        // Postgres serialises bytea as "\x..." hex prefix. Show byte count
        // instead of dumping kilobytes of hex into the cell.
        let stripped = raw.hasPrefix("\\x") ? String(raw.dropFirst(2)) : raw
        let byteCount = max(0, stripped.count / 2)
        let label = "〈\(byteCount.formatted(.number)) bytes〉"
        return Rendered(
            attributed: plain(label, color: .tertiaryLabelColor, font: italicFont()),
            alignment: .left,
            font: italicFont(),
            rawForEditor: raw
        )
    }

    private static func text(_ raw: String, kind: ColumnTypeKind) -> Rendered {
        Rendered(
            attributed: plain(raw, color: .labelColor, font: body),
            alignment: .left,
            font: body,
            rawForEditor: raw
        )
    }

    // MARK: - Staged non-literal values

    /// A dim italic stand-in — "DEFAULT" on a draft row's untouched cell.
    static func renderPlaceholder(_ text: String, column: ColumnNode) -> Rendered {
        let kind = ColumnTypeKind.from(typeName: column.typeName)
        return withParagraphStyle(Rendered(
            attributed: NSAttributedString(string: text, attributes: [
                .font: italicFont(),
                .foregroundColor: NSColor.tertiaryLabelColor,
            ]),
            alignment: alignment(for: kind),
            font: italicFont(),
            rawForEditor: ""
        ))
    }

    /// A staged SQL expression or DEFAULT, tinted so it can't be mistaken
    /// for a literal value.
    static func renderExpression(_ text: String, column: ColumnNode) -> Rendered {
        let kind = ColumnTypeKind.from(typeName: column.typeName)
        let tint = NSColor(red: 0.42, green: 0.32, blue: 0.86, alpha: 1)
        let attr = NSMutableAttributedString(string: "ƒ ", attributes: [
            .font: italicFont(),
            .foregroundColor: tint.withAlphaComponent(0.7),
        ])
        attr.append(NSAttributedString(string: text, attributes: [
            .font: monoText,
            .foregroundColor: tint,
        ]))
        return withParagraphStyle(Rendered(
            attributed: attr,
            alignment: alignment(for: kind),
            font: monoText,
            rawForEditor: text
        ))
    }

    // MARK: - Helpers

    private static func plain(_ s: String, color: NSColor, font: NSFont) -> NSAttributedString {
        NSAttributedString(string: s, attributes: [
            .font: font,
            .foregroundColor: color,
        ])
    }

    private static func nullString() -> NSAttributedString {
        NSAttributedString(string: "NULL", attributes: [
            .font: italicFont(),
            .foregroundColor: NSColor.tertiaryLabelColor,
        ])
    }

    private static func italicFont() -> NSFont {
        let descriptor = NSFont.systemFont(ofSize: baseSize).fontDescriptor.withSymbolicTraits(.italic)
        return NSFont(descriptor: descriptor, size: baseSize) ?? body
    }

    static func alignment(for kind: ColumnTypeKind) -> NSTextAlignment {
        switch kind {
        case .integer, .number: return .right
        case .bool: return .center
        default: return .left
        }
    }
}
