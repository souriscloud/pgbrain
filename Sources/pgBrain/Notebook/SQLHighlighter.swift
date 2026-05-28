import AppKit

/// Cheap-but-good single-pass SQL syntax highlighter. Designed to be
/// attached as an `NSTextStorage` delegate so it re-applies attributes
/// on every edit. The scanner walks the string once and tags ranges as
/// keyword / function / string / comment / number; everything else
/// gets the default label colour.
///
/// We deliberately keep this lightweight (no AST, no streaming parser)
/// so it can run in `processEditing` without burning CPU on each
/// keystroke. The cost is that we miss things only a real parser would
/// catch (e.g. nested block comments past one level) — for a SQL
/// scratchpad that trade is fine.
final class SQLHighlighter: NSObject, NSTextStorageDelegate, @unchecked Sendable {
    static let shared = SQLHighlighter()

    /// Reused for every cell so the keyword set isn't rebuilt per
    /// keystroke.
    private static let keywords: Set<String> = [
        "select", "from", "where", "and", "or", "not", "in", "is", "null",
        "as", "on", "join", "left", "right", "inner", "outer", "full",
        "cross", "lateral", "using", "group", "by", "having", "order",
        "limit", "offset", "fetch", "next", "first", "rows", "only",
        "with", "recursive", "returning",
        "insert", "into", "values", "update", "set", "delete", "truncate",
        "create", "table", "view", "index", "unique", "primary", "key",
        "foreign", "references", "constraint", "check", "default", "if",
        "exists", "drop", "alter", "add", "rename", "to", "column",
        "begin", "commit", "rollback", "savepoint", "transaction",
        "case", "when", "then", "else", "end", "between", "like", "ilike",
        "similar", "escape", "asc", "desc", "distinct", "all", "any",
        "exists", "union", "intersect", "except", "cast", "extract",
        "interval", "true", "false", "unknown", "explain", "analyze",
        "vacuum", "reindex", "grant", "revoke", "comment", "show",
    ]

    private static let functions: Set<String> = [
        "count", "sum", "avg", "min", "max", "coalesce", "nullif",
        "now", "current_timestamp", "current_date", "current_user",
        "to_char", "to_date", "to_timestamp", "to_number",
        "concat", "length", "substring", "trim", "lower", "upper",
        "replace", "regexp_replace", "regexp_matches",
        "json_build_object", "jsonb_build_object", "json_agg", "jsonb_agg",
        "array_agg", "string_agg", "row_number", "rank", "dense_rank",
        "lag", "lead", "first_value", "last_value", "generate_series",
    ]

    /// Apply highlighting to `storage`. Intended for both the
    /// processEditing-driven path and the explicit "highlight everything"
    /// pass right after we set the text up front. Reads the editor font
    /// size from the storage's *existing* attributes so we don't have to
    /// hop to the main actor for `AppSettings.shared`.
    nonisolated func highlight(_ storage: NSTextStorage) {
        let text = storage.string as NSString
        let full = NSRange(location: 0, length: text.length)
        guard full.length > 0 else { return }

        // Read existing font (set by the host NSTextView) to keep size
        // consistent without crossing the main-actor boundary.
        let baseFont: NSFont = {
            if let existing = storage.attribute(.font, at: 0, effectiveRange: nil) as? NSFont {
                return NSFont.monospacedSystemFont(ofSize: existing.pointSize, weight: .regular)
            }
            return NSFont.monospacedSystemFont(ofSize: 13, weight: .regular)
        }()

        // Strip styling, restore base attrs.
        storage.removeAttribute(.foregroundColor, range: full)
        storage.removeAttribute(.font, range: full)
        storage.addAttribute(.font, value: baseFont, range: full)
        storage.addAttribute(.foregroundColor, value: NSColor.labelColor, range: full)

        var i = 0
        let n = text.length
        while i < n {
            let scalar = text.character(at: i)
            // Comments — `--` to end of line, `/* */` block.
            if scalar == 0x2D /* '-' */, i + 1 < n, text.character(at: i + 1) == 0x2D {
                let lineEnd = text.range(of: "\n", options: [], range: NSRange(location: i, length: n - i))
                let end = lineEnd.location == NSNotFound ? n : lineEnd.location
                let range = NSRange(location: i, length: end - i)
                storage.addAttribute(.foregroundColor, value: Self.commentColor, range: range)
                if let italic = Self.italicFont(baseFont) {
                    storage.addAttribute(.font, value: italic, range: range)
                }
                i = end
                continue
            }
            if scalar == 0x2F /* '/' */, i + 1 < n, text.character(at: i + 1) == 0x2A {
                // Find matching `*/`.
                let search = NSRange(location: i + 2, length: n - i - 2)
                let close = text.range(of: "*/", options: [], range: search)
                let end = close.location == NSNotFound ? n : close.location + 2
                let range = NSRange(location: i, length: end - i)
                storage.addAttribute(.foregroundColor, value: Self.commentColor, range: range)
                if let italic = Self.italicFont(baseFont) {
                    storage.addAttribute(.font, value: italic, range: range)
                }
                i = end
                continue
            }
            // String literal — single-quoted, with '' escape.
            if scalar == 0x27 /* "'" */ {
                var j = i + 1
                while j < n {
                    if text.character(at: j) == 0x27 {
                        if j + 1 < n, text.character(at: j + 1) == 0x27 {
                            j += 2; continue
                        }
                        j += 1; break
                    }
                    j += 1
                }
                let range = NSRange(location: i, length: j - i)
                storage.addAttribute(.foregroundColor, value: Self.stringColor, range: range)
                i = j
                continue
            }
            // Double-quoted identifier — render dimly so the user sees
            // the quoting without it screaming.
            if scalar == 0x22 /* '"' */ {
                var j = i + 1
                while j < n, text.character(at: j) != 0x22 { j += 1 }
                if j < n { j += 1 }
                let range = NSRange(location: i, length: j - i)
                storage.addAttribute(.foregroundColor, value: Self.identifierColor, range: range)
                i = j
                continue
            }
            // Number — digits with optional decimal.
            if isDigit(scalar) {
                var j = i + 1
                while j < n {
                    let c = text.character(at: j)
                    if isDigit(c) || c == 0x2E /* '.' */ { j += 1 } else { break }
                }
                let range = NSRange(location: i, length: j - i)
                storage.addAttribute(.foregroundColor, value: Self.numberColor, range: range)
                i = j
                continue
            }
            // Identifier / keyword / function.
            if isIdentStart(scalar) {
                var j = i + 1
                while j < n, isIdentCont(text.character(at: j)) { j += 1 }
                let range = NSRange(location: i, length: j - i)
                let word = text.substring(with: range).lowercased()
                if Self.keywords.contains(word) {
                    storage.addAttribute(.foregroundColor, value: Self.keywordColor, range: range)
                    if let bold = Self.boldFont(baseFont) {
                        storage.addAttribute(.font, value: bold, range: range)
                    }
                } else if Self.functions.contains(word) {
                    storage.addAttribute(.foregroundColor, value: Self.functionColor, range: range)
                }
                i = j
                continue
            }
            i += 1
        }
    }

    /// One-shot helper for SwiftUI — wraps `highlight(_:)` so static
    /// SQL text (DDL pane, scratchpad result previews, etc.) can be
    /// painted with the same lexer the notebook cells use.
    nonisolated static func attributedString(for text: String,
                                              baseFont: NSFont = .monospacedSystemFont(ofSize: 13, weight: .regular)) -> AttributedString {
        let storage = NSTextStorage(string: text, attributes: [.font: baseFont])
        SQLHighlighter.shared.highlight(storage)
        return AttributedString(storage)
    }

    // MARK: - NSTextStorageDelegate

    func textStorage(
        _ textStorage: NSTextStorage,
        didProcessEditing editedMask: NSTextStorageEditActions,
        range editedRange: NSRange,
        changeInLength delta: Int
    ) {
        // Re-highlight the entire storage. For our cell-sized text this
        // is fast enough; line-level incremental highlighting can come
        // later if profiling says otherwise.
        guard editedMask.contains(.editedCharacters) else { return }
        highlight(textStorage)
    }

    // MARK: - Helpers

    private func isDigit(_ c: unichar) -> Bool { c >= 0x30 && c <= 0x39 }
    private func isIdentStart(_ c: unichar) -> Bool {
        (c >= 0x41 && c <= 0x5A) || (c >= 0x61 && c <= 0x7A) || c == 0x5F /* _ */
    }
    private func isIdentCont(_ c: unichar) -> Bool {
        isIdentStart(c) || isDigit(c)
    }

    private static func boldFont(_ base: NSFont) -> NSFont? {
        NSFont(descriptor: base.fontDescriptor.withSymbolicTraits(.bold), size: base.pointSize)
    }
    private static func italicFont(_ base: NSFont) -> NSFont? {
        NSFont(descriptor: base.fontDescriptor.withSymbolicTraits(.italic), size: base.pointSize)
    }

    // Colors chosen to read well in both light and dark mode — Apple's
    // semantic colour roles aren't expressive enough for syntax
    // highlighting, so we pick muted RGB values that work on both.
    private static let keywordColor = NSColor(name: nil) { ap in
        ap.bestMatch(from: [.darkAqua, .vibrantDark]) == nil
            ? NSColor(red: 0.42, green: 0.32, blue: 0.86, alpha: 1.0)   // violet for light
            : NSColor(red: 0.78, green: 0.68, blue: 1.0,  alpha: 1.0)   // softer violet for dark
    }
    private static let stringColor = NSColor(name: nil) { ap in
        ap.bestMatch(from: [.darkAqua, .vibrantDark]) == nil
            ? NSColor(red: 0.16, green: 0.50, blue: 0.27, alpha: 1.0)
            : NSColor(red: 0.55, green: 0.85, blue: 0.62, alpha: 1.0)
    }
    private static let commentColor = NSColor.tertiaryLabelColor
    private static let numberColor = NSColor(name: nil) { ap in
        ap.bestMatch(from: [.darkAqua, .vibrantDark]) == nil
            ? NSColor(red: 0.60, green: 0.30, blue: 0.10, alpha: 1.0)
            : NSColor(red: 0.94, green: 0.70, blue: 0.45, alpha: 1.0)
    }
    private static let identifierColor = NSColor.secondaryLabelColor
    private static let functionColor = NSColor(name: nil) { ap in
        ap.bestMatch(from: [.darkAqua, .vibrantDark]) == nil
            ? NSColor(red: 0.10, green: 0.36, blue: 0.65, alpha: 1.0)
            : NSColor(red: 0.55, green: 0.78, blue: 1.0,  alpha: 1.0)
    }
}
