import Foundation

/// Lightweight scope analyzer driven by `SQLTokenizer`. Given the
/// full editor text + the caret's character index, it answers two
/// questions the completion provider cares about:
///
/// 1. **What's in scope?** — the tables (with aliases) that have been
///    referenced in the FROM / JOIN / UPDATE / INSERT-INTO clauses of
///    the *statement containing the caret*. We split on top-level `;`
///    so completions in statement #2 don't pollute from #1.
/// 2. **What kind of completion makes sense here?** — based on the
///    nearest preceding clause keyword (FROM → tables, WHERE → columns,
///    etc.) plus any `alias.` qualifier touching the caret.
///
/// This is intentionally not a full SQL parser. It handles the
/// shapes you actually type day-to-day:
///   - `FROM users [AS] u`
///   - `FROM schema.users u`
///   - `FROM "Quoted"."Table" t`
///   - `FROM a, b JOIN c ON …`
///   - chained JOINs
///   - sub-statements separated by `;`
/// Subqueries with their own scope (`FROM (SELECT …) sub`) aren't
/// parsed — the sub is treated as opaque, which is fine for v1.
@MainActor
enum SQLScope {
    enum ContextKind { case table, column, orderBy, general }

    struct TableRef: Equatable {
        let schema: String?   // nil = use search_path
        let table: String
        let alias: String?    // canonical lowercased alias if any
    }

    struct Analysis {
        let context: ContextKind
        let references: [TableRef]
        /// `alias.` or `tablename.` touching the caret (with no
        /// whitespace between the dot and the cursor). The provider
        /// uses this to suggest exactly that thing's children.
        let qualifier: String?
    }

    static func analyze(text: String, caretIndex: Int) -> Analysis {
        let allTokens = SQLTokenizer.tokenize(text)
        let stmtTokens = tokensInStatement(allTokens, caret: caretIndex)
        let preCaretTokens = stmtTokens.filter { $0.range.location < caretIndex }

        let references = extractReferences(in: stmtTokens)
        let context = contextKind(preCaretTokens: preCaretTokens)
        let qualifier = trailingQualifier(in: text, caretIndex: caretIndex, tokens: preCaretTokens)

        return Analysis(context: context, references: references, qualifier: qualifier)
    }

    // MARK: - Statement slicing

    /// Tokens of the single `;`-terminated statement containing the
    /// caret. `;` is recognised as a top-level statement boundary
    /// (string / comment tokens never carry punctuation, so this is
    /// trivial post-tokenization).
    private static func tokensInStatement(_ tokens: [SQLToken], caret: Int) -> [SQLToken] {
        var start = 0
        var end = tokens.count
        for (i, t) in tokens.enumerated() {
            if case .punct(let c) = t.kind, c == ";" {
                if t.range.location < caret { start = i + 1 }
                else if t.range.location >= caret { end = i; break }
            }
        }
        return Array(tokens[start..<end])
    }

    // MARK: - Table references

    /// Walk the statement once, collecting tables introduced by FROM /
    /// JOIN / UPDATE / INTO clauses, with optional aliases.
    private static func extractReferences(in tokens: [SQLToken]) -> [TableRef] {
        var refs: [TableRef] = []
        var i = 0
        while i < tokens.count {
            let token = tokens[i]
            guard case .keyword(let kw) = token.kind else { i += 1; continue }
            // Keywords that open a table-list clause.
            if kw == "from" || kw == "join" || kw == "update" || kw == "into" {
                i += 1
                // Read one table reference, then optionally more
                // comma-separated. JOIN: stop at ON / USING / next clause.
                while i < tokens.count {
                    if let (ref, consumed) = readTableRef(tokens: tokens, from: i) {
                        refs.append(ref)
                        i += consumed
                    } else {
                        break
                    }
                    // Comma → another table from this same FROM/INTO.
                    if i < tokens.count, case .punct(",") = tokens[i].kind {
                        i += 1; continue
                    }
                    break
                }
                continue
            }
            i += 1
        }
        return refs
    }

    /// Reads `[schema "."] table [["AS"] alias]` starting at `from`.
    /// Returns the parsed `TableRef` + how many tokens were consumed.
    private static func readTableRef(tokens: [SQLToken], from: Int) -> (TableRef, Int)? {
        var i = from
        guard i < tokens.count else { return nil }
        // First identifier (schema OR table).
        guard let first = identString(tokens[i]) else { return nil }
        i += 1
        var schema: String? = nil
        var table = first
        // Optional `.` then second identifier (real table name).
        if i + 1 < tokens.count,
           case .punct(".") = tokens[i].kind,
           let second = identString(tokens[i + 1]) {
            schema = first
            table = second
            i += 2
        }
        // Optional alias — `[AS] ident`. AS is a keyword in our table.
        var alias: String? = nil
        if i < tokens.count, case .keyword("as") = tokens[i].kind {
            i += 1
            if i < tokens.count, let a = identString(tokens[i]) {
                alias = a.lowercased(); i += 1
            }
        } else if i < tokens.count,
                  let a = identString(tokens[i]),
                  // Bare identifier alias — but only if it's not the
                  // next clause keyword (FROM users WHERE …) and not a
                  // JOIN-related keyword. identString already filters
                  // keywords, so any bare identifier qualifies.
                  shouldTreatAsAlias(tokens, at: i) {
            alias = a.lowercased(); i += 1
        }
        return (TableRef(schema: schema, table: table, alias: alias), i - from)
    }

    /// Bare identifier after a table name *might* be an alias, OR it
    /// might be the next keyword we don't know about. Treat as alias
    /// when the following token is a comma, clause keyword, ON, USING,
    /// or end of input.
    private static func shouldTreatAsAlias(_ tokens: [SQLToken], at i: Int) -> Bool {
        let nextIdx = i + 1
        guard nextIdx < tokens.count else { return true }
        let next = tokens[nextIdx]
        switch next.kind {
        case .punct(let c) where c == "," || c == ";": return true
        case .keyword(let kw):
            return Self.followsAlias.contains(kw)
        default:
            return false
        }
    }
    private static let followsAlias: Set<String> = [
        "on", "using", "where", "join", "left", "right", "inner", "outer",
        "full", "cross", "group", "order", "having", "limit", "offset",
        "returning", "union", "intersect", "except", "set", "values",
    ]

    private static func identString(_ token: SQLToken) -> String? {
        switch token.kind {
        case .identifier(let s):    return s
        case .quotedIdent(let s):   return s
        default:                    return nil
        }
    }

    // MARK: - Context detection

    /// Walks the pre-caret tokens backward to find the most recent
    /// clause keyword that influences completion meaning.
    private static func contextKind(preCaretTokens: [SQLToken]) -> ContextKind {
        for token in preCaretTokens.reversed() {
            guard case .keyword(let kw) = token.kind else { continue }
            // Two-word `ORDER BY` / `GROUP BY` show up as separate
            // tokens; "by" alone is enough to flip us into orderBy
            // mode (functionally equivalent for completion).
            if kw == "by" { return .orderBy }
            if Self.tableContextKeywords.contains(kw) { return .table }
            if Self.columnContextKeywords.contains(kw) { return .column }
        }
        return .general
    }
    private static let tableContextKeywords: Set<String> = [
        "from", "join", "into", "update", "table", "references", "delete",
    ]
    private static let columnContextKeywords: Set<String> = [
        "select", "where", "and", "or", "on", "set", "having", "returning",
        "when", "then", "case",
    ]

    // MARK: - Qualifier detection

    /// Returns the identifier immediately followed by a `.` right
    /// before the caret (no whitespace between the dot and the caret),
    /// or nil otherwise. Uses the raw text so we catch `users.` even
    /// when the partial word hasn't started yet.
    private static func trailingQualifier(in text: String, caretIndex: Int, tokens: [SQLToken]) -> String? {
        let ns = text as NSString
        guard caretIndex > 0, caretIndex <= ns.length else { return nil }
        // Walk back through word chars to the start of the current partial.
        var i = caretIndex
        while i > 0 {
            let c = ns.character(at: i - 1)
            if isWordChar(c) { i -= 1 } else { break }
        }
        // We need a `.` immediately preceding the partial's start.
        guard i > 0, ns.character(at: i - 1) == 0x2E /* '.' */ else { return nil }
        // The identifier sitting in front of the `.`.
        var j = i - 1
        var start = j
        while start > 0 {
            let c = ns.character(at: start - 1)
            if isWordChar(c) { start -= 1 } else { break }
        }
        guard start < j else { return nil }
        return ns.substring(with: NSRange(location: start, length: j - start))
    }

    private static func isWordChar(_ c: unichar) -> Bool {
        (c >= 0x41 && c <= 0x5A) || (c >= 0x61 && c <= 0x7A) ||
        (c >= 0x30 && c <= 0x39) || c == 0x5F
    }
}
