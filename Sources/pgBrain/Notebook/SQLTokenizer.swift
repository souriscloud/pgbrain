import Foundation

/// The one PostgreSQL lexer shared by the statement splitter, the safety
/// classifier, the completion/format tokenizer and the schema duplicator's
/// retargeting. Works on UTF-16 code units so ranges line up with `NSString`
/// / `NSRange`, and so a CRLF pair (a single Swift `Character`) is still seen
/// as two separate line-break units.
///
/// Covers the lexical rules that matter for statement boundaries and keyword
/// sniffing: `''`-doubled strings, `E'…'` escape strings (backslash escapes),
/// `B''`/`X''`/`N''`/`U&''` prefixes, `"quoted"` identifiers, `$tag$…$tag$`
/// dollar quotes (but not `$1` parameters or the `$` inside `a$b`), nested
/// `/* */` comments and `--` line comments. Unterminated constructs run to
/// the end of the input — the server will report them, we just mustn't split
/// or classify inside them.
enum SQLLexer {
    enum Kind: Equatable {
        case whitespace
        case lineComment
        case blockComment
        case string          // '…', E'…', B'…', X'…', N'…', U&'…'
        case dollarString    // $tag$…$tag$
        case quotedIdent     // "…" or U&"…"
        case word            // identifier or keyword (may contain `$`)
        case number
        case parameter       // $1, $2 …
        case op
        case punct           // . , ; ( ) [ ]
    }

    struct Token: Equatable {
        let kind: Kind
        /// Range in UTF-16 code units of the source string.
        let range: NSRange
        var upperBound: Int { range.location + range.length }
    }

    static func lex(_ text: String) -> [Token] {
        lex(utf16: Array(text.utf16))
    }

    static func lex(utf16 u: [UInt16]) -> [Token] {
        let n = u.count
        var out: [Token] = []
        out.reserveCapacity(n / 3)
        var i = 0

        func emit(_ k: Kind, _ start: Int, _ end: Int) {
            out.append(Token(kind: k, range: NSRange(location: start, length: end - start)))
        }
        func at(_ j: Int) -> UInt16 { j < n ? u[j] : 0 }

        while i < n {
            let c = u[i]
            let start = i

            if isSpace(c) {
                while i < n, isSpace(u[i]) { i += 1 }
                emit(.whitespace, start, i); continue
            }
            if c == 0x2D, at(i + 1) == 0x2D {                            // --
                i += 2
                while i < n, u[i] != 0x0A, u[i] != 0x0D { i += 1 }
                emit(.lineComment, start, i); continue
            }
            if c == 0x2F, at(i + 1) == 0x2A {                            // /*
                i = skipBlockComment(u, from: i)
                emit(.blockComment, start, i); continue
            }
            if c == 0x27 {                                               // '
                i = skipString(u, from: i, backslashEscapes: false)
                emit(.string, start, i); continue
            }
            if c == 0x22 {                                               // "
                i = skipQuotedIdent(u, from: i)
                emit(.quotedIdent, start, i); continue
            }
            if isIdentStart(c) {
                let next = at(i + 1)
                if next == 0x27, c < 0x80 {
                    switch c | 0x20 {
                    case 0x65:                                            // E'…'
                        i = skipString(u, from: i + 1, backslashEscapes: true)
                        emit(.string, start, i); continue
                    case 0x62, 0x78, 0x6E:                                // B'…' X'…' N'…'
                        i = skipString(u, from: i + 1, backslashEscapes: false)
                        emit(.string, start, i); continue
                    default: break
                    }
                }
                if c < 0x80, (c | 0x20) == 0x75, next == 0x26 {           // U&
                    let q = at(i + 2)
                    if q == 0x27 {
                        i = skipString(u, from: i + 2, backslashEscapes: false)
                        emit(.string, start, i); continue
                    }
                    if q == 0x22 {
                        i = skipQuotedIdent(u, from: i + 2)
                        emit(.quotedIdent, start, i); continue
                    }
                }
                i += 1
                while i < n, isIdentChar(u[i]) { i += 1 }
                emit(.word, start, i); continue
            }
            if isDigit(c) || (c == 0x2E && isDigit(at(i + 1))) {
                i = skipNumber(u, from: i)
                emit(.number, start, i); continue
            }
            if c == 0x24 {                                               // $
                if isDigit(at(i + 1)) {
                    i += 1
                    while i < n, isDigit(u[i]) { i += 1 }
                    emit(.parameter, start, i); continue
                }
                if let tagLen = dollarOpenerLength(u, at: i) {
                    i = skipDollarBody(u, from: i + tagLen, openerStart: i, tagLen: tagLen)
                    emit(.dollarString, start, i); continue
                }
                i += 1
                emit(.op, start, i); continue
            }
            if c == 0x2E || c == 0x2C || c == 0x3B || c == 0x28 || c == 0x29 || c == 0x5B || c == 0x5D {
                i += 1
                emit(.punct, start, i); continue
            }
            i += operatorLength(u, at: i)
            emit(.op, start, i)
        }
        return out
    }

    // MARK: - Helpers for consumers

    static func text(_ t: Token, in u: [UInt16]) -> String {
        String(decoding: u[t.range.location ..< t.upperBound], as: UTF16.self)
    }

    /// Lowercased text of a `word` token — keyword comparisons only.
    static func lowerWord(_ t: Token, in u: [UInt16]) -> String {
        text(t, in: u).lowercased()
    }

    /// Unescaped body of a `quotedIdent` token (`"a""b"` → `a"b`).
    static func quotedIdentBody(_ t: Token, in u: [UInt16]) -> String {
        var lo = t.range.location
        var hi = t.upperBound
        if u[lo] != 0x22 { lo += 2 }                                      // U& prefix
        lo += 1
        if hi - 1 >= lo, u[hi - 1] == 0x22 { hi -= 1 }
        guard hi > lo else { return "" }
        return String(decoding: u[lo..<hi], as: UTF16.self).replacingOccurrences(of: "\"\"", with: "\"")
    }

    static func isTrivia(_ k: Kind) -> Bool {
        k == .whitespace || k == .lineComment || k == .blockComment
    }

    // MARK: - Scanners

    private static func skipString(_ u: [UInt16], from quote: Int, backslashEscapes: Bool) -> Int {
        var i = quote + 1
        let n = u.count
        while i < n {
            let c = u[i]
            if backslashEscapes, c == 0x5C { i += 2; continue }
            if c == 0x27 {
                if i + 1 < n, u[i + 1] == 0x27 { i += 2; continue }
                return i + 1
            }
            i += 1
        }
        return n
    }

    private static func skipQuotedIdent(_ u: [UInt16], from quote: Int) -> Int {
        var i = quote + 1
        let n = u.count
        while i < n {
            if u[i] == 0x22 {
                if i + 1 < n, u[i + 1] == 0x22 { i += 2; continue }
                return i + 1
            }
            i += 1
        }
        return n
    }

    private static func skipBlockComment(_ u: [UInt16], from start: Int) -> Int {
        var i = start + 2
        var depth = 1
        let n = u.count
        while i < n {
            if u[i] == 0x2F, i + 1 < n, u[i + 1] == 0x2A { depth += 1; i += 2; continue }
            if u[i] == 0x2A, i + 1 < n, u[i + 1] == 0x2F {
                depth -= 1; i += 2
                if depth == 0 { return i }
                continue
            }
            i += 1
        }
        return n
    }

    private static func skipNumber(_ u: [UInt16], from start: Int) -> Int {
        let n = u.count
        var i = start
        if u[i] == 0x30, i + 1 < n, [0x78, 0x58, 0x6F, 0x4F, 0x62, 0x42].contains(u[i + 1]),
           i + 2 < n, isHexDigit(u[i + 2]) {
            i += 2
            while i < n, isHexDigit(u[i]) || u[i] == 0x5F { i += 1 }
            return i
        }
        while i < n, isDigit(u[i]) || u[i] == 0x5F { i += 1 }
        // `1..2` isn't a decimal; only take the dot when it isn't doubled.
        if i < n, u[i] == 0x2E, !(i + 1 < n && u[i + 1] == 0x2E) {
            i += 1
            while i < n, isDigit(u[i]) || u[i] == 0x5F { i += 1 }
        }
        if i < n, u[i] == 0x65 || u[i] == 0x45 {
            var j = i + 1
            if j < n, u[j] == 0x2B || u[j] == 0x2D { j += 1 }
            if j < n, isDigit(u[j]) {
                i = j
                while i < n, isDigit(u[i]) { i += 1 }
            }
        }
        return i
    }

    /// `$` opens a dollar quote only when followed by `$`, or by a valid tag
    /// (identifier start, then identifier chars excluding `$`) and a closing
    /// `$`. The caller only reaches here at a token start, so a `$` glued to
    /// a preceding identifier (`a$b`) has already been eaten by the word rule.
    /// Returns the opener length (`$tag$` → 5).
    private static func dollarOpenerLength(_ u: [UInt16], at i: Int) -> Int? {
        let n = u.count
        var j = i + 1
        guard j < n else { return nil }
        if u[j] == 0x24 { return 2 }
        guard isIdentStart(u[j]) else { return nil }
        j += 1
        while j < n, u[j] != 0x24, isIdentChar(u[j]) { j += 1 }
        guard j < n, u[j] == 0x24 else { return nil }
        return j + 1 - i
    }

    private static func skipDollarBody(_ u: [UInt16], from body: Int, openerStart: Int, tagLen: Int) -> Int {
        let n = u.count
        var i = body
        while i + tagLen <= n {
            if u[i] == 0x24 {
                var match = true
                for k in 1..<tagLen where u[i + k] != u[openerStart + k] { match = false; break }
                if match { return i + tagLen }
            }
            i += 1
        }
        return n
    }

    private static func operatorLength(_ u: [UInt16], at i: Int) -> Int {
        guard i + 1 < u.count else { return 1 }
        switch (u[i], u[i + 1]) {
        case (0x3A, 0x3A),                       // ::
             (0x3C, 0x3E), (0x3C, 0x3D),         // <> <=
             (0x3E, 0x3D), (0x21, 0x3D),         // >= !=
             (0x7C, 0x7C),                       // ||
             (0x3D, 0x3E), (0x3A, 0x3D):         // => :=
            return 2
        default:
            return 1
        }
    }

    // MARK: - Character classes

    static func isSpace(_ c: UInt16) -> Bool {
        c == 0x20 || c == 0x09 || c == 0x0A || c == 0x0D || c == 0x0C || c == 0x0B
    }
    static func isDigit(_ c: UInt16) -> Bool { c >= 0x30 && c <= 0x39 }
    private static func isHexDigit(_ c: UInt16) -> Bool {
        isDigit(c) || (c >= 0x41 && c <= 0x46) || (c >= 0x61 && c <= 0x66)
    }
    /// PostgreSQL treats every byte ≥ 0x80 as an identifier letter, so every
    /// non-ASCII code unit (surrogate halves included) counts.
    static func isIdentStart(_ c: UInt16) -> Bool {
        (c >= 0x41 && c <= 0x5A) || (c >= 0x61 && c <= 0x7A) || c == 0x5F || c >= 0x80
    }
    static func isIdentChar(_ c: UInt16) -> Bool {
        isIdentStart(c) || isDigit(c) || c == 0x24
    }
}

/// Completion/format-facing token stream, built on `SQLLexer`.
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
    /// UTF-16 range in the source string (NSString units).
    let range: NSRange
}

enum SQLTokenizer {
    /// Recognised Postgres keywords used by the scope analyzer and the
    /// formatter. Anything outside this set is an `identifier`, even if
    /// Postgres treats it as a keyword elsewhere — fine for completion context.
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
        let u = Array(text.utf16)
        var out: [SQLToken] = []
        for t in SQLLexer.lex(utf16: u) {
            switch t.kind {
            case .whitespace:
                continue
            case .lineComment, .blockComment:
                out.append(SQLToken(kind: .comment, range: t.range))
            case .string, .dollarString:
                out.append(SQLToken(kind: .string, range: t.range))
            case .quotedIdent:
                out.append(SQLToken(kind: .quotedIdent(SQLLexer.quotedIdentBody(t, in: u)), range: t.range))
            case .word:
                let word = SQLLexer.text(t, in: u)
                let upper = word.uppercased()
                out.append(SQLToken(kind: keywords.contains(upper) ? .keyword(upper.lowercased()) : .identifier(word),
                                    range: t.range))
            case .number:
                out.append(SQLToken(kind: .number, range: t.range))
            case .parameter:
                // Kept as `$` + number so existing consumers (and their
                // exhaustive switches) see the same shape as before.
                out.append(SQLToken(kind: .op("$"), range: NSRange(location: t.range.location, length: 1)))
                out.append(SQLToken(kind: .number, range: NSRange(location: t.range.location + 1, length: t.range.length - 1)))
            case .punct:
                let ch = Character(UnicodeScalar(u[t.range.location]) ?? "?")
                if ch == "[" || ch == "]" {
                    out.append(SQLToken(kind: .op(String(ch)), range: t.range))
                } else {
                    out.append(SQLToken(kind: .punct(ch), range: t.range))
                }
            case .op:
                out.append(SQLToken(kind: .op(SQLLexer.text(t, in: u)), range: t.range))
            }
        }
        return out
    }
}
