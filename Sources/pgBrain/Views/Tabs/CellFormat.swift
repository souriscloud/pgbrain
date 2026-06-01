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

    private static let intFormatter: NumberFormatter = {
        let f = NumberFormatter()
        f.numberStyle = .decimal
        f.usesGroupingSeparator = true
        f.maximumFractionDigits = 0
        return f
    }()

    private static let decimalFormatter: NumberFormatter = {
        let f = NumberFormatter()
        f.numberStyle = .decimal
        f.usesGroupingSeparator = true
        f.minimumFractionDigits = 0
        f.maximumFractionDigits = 6
        return f
    }()

    /// Postgres ships timestamps as "YYYY-MM-DD HH:MM:SS[.ffffff][+TZ]".
    /// Try a few common shapes; fall back to the raw string if none parse.
    private static let timestampParsers: [DateFormatter] = {
        let formats = [
            "yyyy-MM-dd HH:mm:ssZ",
            "yyyy-MM-dd HH:mm:ss",
            "yyyy-MM-dd HH:mm:ss.SSSSSS",
            "yyyy-MM-dd HH:mm:ss.SSSSSSZ",
            "yyyy-MM-dd HH:mm:ss.SSS",
            "yyyy-MM-dd HH:mm:ss.SSSZ",
        ]
        return formats.map {
            let f = DateFormatter()
            f.locale = Locale(identifier: "en_US_POSIX")
            f.dateFormat = $0
            return f
        }
    }()

    private static let timestampDisplay: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd HH:mm:ss"
        return f
    }()

    private static let dateDisplay: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd"
        return f
    }()

    private static func integer(_ raw: String, kind: ColumnTypeKind) -> Rendered {
        let trimmed = raw.trimmingCharacters(in: .whitespaces)
        let formatted: String
        if let n = Int64(trimmed), let s = intFormatter.string(from: NSNumber(value: n)) {
            formatted = s
        } else {
            formatted = trimmed
        }
        return Rendered(
            attributed: plain(formatted, color: .labelColor, font: mono),
            alignment: .right,
            font: mono,
            rawForEditor: raw
        )
    }

    private static func number(_ raw: String, kind: ColumnTypeKind) -> Rendered {
        let trimmed = raw.trimmingCharacters(in: .whitespaces)
        let formatted: String
        if let d = Double(trimmed), let s = decimalFormatter.string(from: NSNumber(value: d)) {
            formatted = s
        } else {
            formatted = trimmed
        }
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

    private static func dateOnly(_ raw: String) -> Rendered {
        let str: String
        if let d = parseDate(raw) {
            str = dateDisplay.string(from: d)
        } else {
            str = raw
        }
        return Rendered(
            attributed: plain(str, color: .labelColor, font: mono),
            alignment: .left,
            font: mono,
            rawForEditor: raw
        )
    }

    private static func timestamp(_ raw: String) -> Rendered {
        let str: String
        if let d = parseDate(raw) {
            str = timestampDisplay.string(from: d)
        } else {
            str = raw
        }
        return Rendered(
            attributed: plain(str, color: .labelColor, font: mono),
            alignment: .left,
            font: mono,
            rawForEditor: raw
        )
    }

    private static func parseDate(_ raw: String) -> Date? {
        let trimmed = raw.trimmingCharacters(in: .whitespaces)
        for f in timestampParsers {
            if let d = f.date(from: trimmed) { return d }
        }
        return nil
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
        return NSFont(descriptor: descriptor, size: 12) ?? body
    }

    static func alignment(for kind: ColumnTypeKind) -> NSTextAlignment {
        switch kind {
        case .integer, .number: return .right
        case .bool: return .center
        default: return .left
        }
    }
}
