import Foundation

/// Single-pass Postgres-dialect SQL tokenizer. Just enough to drive
/// scope analysis for completions + hover — handles the lexical bits
/// the regex-based detector kept getting wrong:
///
///   - quoted identifiers: `"foo"`, `"with""escape"`
///   - string literals: `'foo'`, `'it''s'`, dollar-quoted `$$body$$` / `$tag$body$tag$`
///   - line + block comments
///   - numbers (`123`, `1.5`, `1e5`)
///   - operators (`::`, `<>`, `!=`, `<=`, `>=`, `||`)
///   - multi-char and single-char punctuation
///
/// We don't try to be a full PL/pgSQL lexer (no nested block comments,
/// no E'...' escape strings) — just the surface dialect used in
/// `SELECT … WHERE …`-shaped statements.
struct SQLToken: Equatable {
    enum Kind: Equatable {
        case keyword(String)       // lowercased
        case identifier(String)    // bare ident as written
        case quotedIdent(String)   // contents between the `"`s
        case string                // body intentionally dropped — we don't need it
        case number
        case punct(Character)      // . , ; ( )
        case op(String)
        case comment
    }
    let kind: Kind
    /// Byte-offset range in the source string (NSString units, so
    /// `String.Index` conversions stay straightforward).
    let range: NSRange
}

enum SQLTokenizer {
    /// All-uppercase set of recognised Postgres reserved + non-reserved
    /// keywords used by our scope analyzer. Anything outside this set
    /// is an `identifier`, even if Postgres treats it as a keyword
    /// elsewhere — that's fine for completion-context purposes.
    private static let keywords: Set<String> = [
        "SELECT", "FROM", "WHERE", "AND", "OR", "NOT", "IN", "IS", "NULL",
        "AS", "ON", "JOIN", "LEFT", "RIGHT", "INNER", "OUTER", "FULL",
        "CROSS", "LATERAL", "USING", "GROUP", "BY", "HAVING", "ORDER",
        "LIMIT", "OFFSET", "FETCH", "NEXT", "FIRST", "ROWS", "ONLY",
        "WITH", "RECURSIVE", "RETURNING",
        "INSERT", "INTO", "VALUES", "UPDATE", "SET", "DELETE", "TRUNCATE",
        "CREATE", "TABLE", "VIEW", "INDEX", "UNIQUE", "PRIMARY", "KEY",
        "FOREIGN", "REFERENCES", "CONSTRAINT", "CHECK", "DEFAULT", "IF",
        "EXISTS", "DROP", "ALTER", "ADD", "RENAME", "TO", "COLUMN",
        "BEGIN", "COMMIT", "ROLLBACK", "SAVEPOINT", "TRANSACTION",
        "CASE", "WHEN", "THEN", "ELSE", "END", "BETWEEN", "LIKE", "ILIKE",
        "SIMILAR", "ESCAPE", "ASC", "DESC", "DISTINCT", "ALL", "ANY",
        "UNION", "INTERSECT", "EXCEPT", "CAST", "EXTRACT", "INTERVAL",
        "TRUE", "FALSE", "UNKNOWN", "NULLS", "FIRST", "LAST",
    ]

    static func tokenize(_ text: String) -> [SQLToken] {
        let ns = text as NSString
        let n = ns.length
        var out: [SQLToken] = []
        var i = 0
        while i < n {
            let c = ns.character(at: i)

            // Whitespace.
            if c == 0x20 || c == 0x09 || c == 0x0A || c == 0x0D {
                i += 1; continue
            }

            // Line comment `-- …`.
            if c == 0x2D /* '-' */, i + 1 < n, ns.character(at: i + 1) == 0x2D {
                let end = nextNewline(in: ns, from: i + 2, length: n) ?? n
                out.append(SQLToken(kind: .comment, range: NSRange(location: i, length: end - i)))
                i = end; continue
            }

            // Block comment `/* … */`. No nesting support — Postgres
            // does nest but we don't need that for completion context.
            if c == 0x2F /* '/' */, i + 1 < n, ns.character(at: i + 1) == 0x2A {
                let search = NSRange(location: i + 2, length: n - i - 2)
                let close = ns.range(of: "*/", options: [], range: search)
                let end = close.location == NSNotFound ? n : close.location + 2
                out.append(SQLToken(kind: .comment, range: NSRange(location: i, length: end - i)))
                i = end; continue
            }

            // String literal `'…'` with `''` escape.
            if c == 0x27 /* "'" */ {
                var j = i + 1
                while j < n {
                    if ns.character(at: j) == 0x27 {
                        if j + 1 < n, ns.character(at: j + 1) == 0x27 { j += 2; continue }
                        j += 1; break
                    }
                    j += 1
                }
                out.append(SQLToken(kind: .string, range: NSRange(location: i, length: j - i)))
                i = j; continue
            }

            // Dollar-quoted string `$tag$…$tag$` (or `$$…$$`).
            if c == 0x24 /* '$' */ {
                // Find the closing `$` of the opening tag.
                var tagEnd = i + 1
                while tagEnd < n {
                    let cc = ns.character(at: tagEnd)
                    if cc == 0x24 { break }
                    if !isIdentChar(cc) { break }   // not a tag — fall through
                    tagEnd += 1
                }
                if tagEnd < n, ns.character(at: tagEnd) == 0x24 {
                    let tag = ns.substring(with: NSRange(location: i, length: tagEnd - i + 1))
                    let search = NSRange(location: tagEnd + 1, length: n - tagEnd - 1)
                    let close = ns.range(of: tag, options: [], range: search)
                    let end = close.location == NSNotFound ? n : close.location + (tagEnd - i + 1)
                    out.append(SQLToken(kind: .string, range: NSRange(location: i, length: end - i)))
                    i = end; continue
                }
                // Not a dollar-quoted string — treat the `$` as punct.
            }

            // Quoted identifier `"…"` with `""` escape.
            if c == 0x22 /* '"' */ {
                var j = i + 1
                var body = ""
                while j < n {
                    let cc = ns.character(at: j)
                    if cc == 0x22 {
                        if j + 1 < n, ns.character(at: j + 1) == 0x22 {
                            body.append("\""); j += 2; continue
                        }
                        j += 1; break
                    }
                    body.append(Character(UnicodeScalar(cc) ?? UnicodeScalar(0x3F)!))
                    j += 1
                }
                out.append(SQLToken(kind: .quotedIdent(body), range: NSRange(location: i, length: j - i)))
                i = j; continue
            }

            // Number — digits with optional decimal / exponent.
            if isDigit(c) {
                var j = i + 1
                while j < n {
                    let cc = ns.character(at: j)
                    if isDigit(cc) || cc == 0x2E /* '.' */ { j += 1; continue }
                    if (cc == 0x65 || cc == 0x45) /* e/E */ { j += 1; continue }
                    if (cc == 0x2B || cc == 0x2D) && j > i + 1 {
                        // Allow exponent sign only if previous was e/E.
                        let prev = ns.character(at: j - 1)
                        if prev == 0x65 || prev == 0x45 { j += 1; continue }
                    }
                    break
                }
                out.append(SQLToken(kind: .number, range: NSRange(location: i, length: j - i)))
                i = j; continue
            }

            // Bare identifier or keyword.
            if isIdentStart(c) {
                var j = i + 1
                while j < n, isIdentChar(ns.character(at: j)) { j += 1 }
                let word = ns.substring(with: NSRange(location: i, length: j - i))
                let upper = word.uppercased()
                if keywords.contains(upper) {
                    out.append(SQLToken(kind: .keyword(upper.lowercased()),
                                        range: NSRange(location: i, length: j - i)))
                } else {
                    out.append(SQLToken(kind: .identifier(word),
                                        range: NSRange(location: i, length: j - i)))
                }
                i = j; continue
            }

            // Multi-char operators / type cast `::`.
            if c == 0x3A /* ':' */, i + 1 < n, ns.character(at: i + 1) == 0x3A {
                out.append(SQLToken(kind: .op("::"), range: NSRange(location: i, length: 2)))
                i += 2; continue
            }
            if c == 0x3C /* '<' */, i + 1 < n {
                let nc = ns.character(at: i + 1)
                if nc == 0x3E { out.append(SQLToken(kind: .op("<>"), range: NSRange(location: i, length: 2))); i += 2; continue }
                if nc == 0x3D { out.append(SQLToken(kind: .op("<="), range: NSRange(location: i, length: 2))); i += 2; continue }
            }
            if c == 0x3E /* '>' */, i + 1 < n, ns.character(at: i + 1) == 0x3D {
                out.append(SQLToken(kind: .op(">="), range: NSRange(location: i, length: 2))); i += 2; continue
            }
            if c == 0x21 /* '!' */, i + 1 < n, ns.character(at: i + 1) == 0x3D {
                out.append(SQLToken(kind: .op("!="), range: NSRange(location: i, length: 2))); i += 2; continue
            }
            if c == 0x7C /* '|' */, i + 1 < n, ns.character(at: i + 1) == 0x7C {
                out.append(SQLToken(kind: .op("||"), range: NSRange(location: i, length: 2))); i += 2; continue
            }

            // Punctuation.
            if c == 0x2E || c == 0x2C || c == 0x3B || c == 0x28 || c == 0x29 {
                let ch = Character(UnicodeScalar(c)!)
                out.append(SQLToken(kind: .punct(ch), range: NSRange(location: i, length: 1)))
                i += 1; continue
            }

            // Single-char operator fallback.
            if let scalar = UnicodeScalar(c) {
                out.append(SQLToken(kind: .op(String(scalar)), range: NSRange(location: i, length: 1)))
            }
            i += 1
        }
        return out
    }

    // MARK: - Char classes

    private static func isDigit(_ c: unichar) -> Bool { c >= 0x30 && c <= 0x39 }
    private static func isIdentStart(_ c: unichar) -> Bool {
        (c >= 0x41 && c <= 0x5A) || (c >= 0x61 && c <= 0x7A) || c == 0x5F
    }
    private static func isIdentChar(_ c: unichar) -> Bool {
        isIdentStart(c) || isDigit(c)
    }
    private static func nextNewline(in ns: NSString, from: Int, length: Int) -> Int? {
        var j = from
        while j < length {
            if ns.character(at: j) == 0x0A { return j }
            j += 1
        }
        return nil
    }
}
