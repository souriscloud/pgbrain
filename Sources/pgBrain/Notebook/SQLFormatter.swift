import Foundation

/// Lightweight SQL pretty-printer. Reuses `SQLTokenizer` and applies
/// a small set of opinionated rules:
///   - top-level clause keywords on their own line (`SELECT`,
///     `FROM`, `WHERE`, `GROUP BY`, `HAVING`, `ORDER BY`, `LIMIT`,
///     `OFFSET`, `RETURNING`, `WITH`, `JOIN`, `LEFT JOIN`, etc.)
///   - keywords uppercased
///   - column lists after SELECT broken onto separate lines, indented
///   - parentheses preserve inner whitespace verbatim (we don't try
///     to descend into sub-queries for v1 — would need a real parser)
///   - strings, comments, identifiers passed through unchanged
///
/// Not a full PG formatter — just enough that `select * from users
/// where id = 1 order by created_at desc` becomes readable.
@MainActor
enum SQLFormatter {
    /// Top-level clauses that get their own line, in the order they
    /// typically appear. Multi-word clauses are matched as token pairs
    /// before the single-word entries.
    private static let multiWordClauses: [[String]] = [
        ["group", "by"], ["order", "by"],
        ["left", "join"], ["right", "join"], ["inner", "join"],
        ["full", "join"], ["cross", "join"], ["full", "outer", "join"],
        ["left", "outer", "join"], ["right", "outer", "join"],
        ["insert", "into"], ["delete", "from"],
        ["union", "all"], ["intersect", "all"], ["except", "all"],
    ]
    private static let singleWordClauses: Set<String> = [
        "select", "from", "where", "having", "limit", "offset",
        "returning", "with", "join", "values", "union", "intersect",
        "except", "set", "on",
    ]

    static func format(_ source: String) -> String {
        let tokens = SQLTokenizer.tokenize(source)
        if tokens.isEmpty { return source }
        let ns = source as NSString

        var output = ""
        var i = 0
        var firstColumnEmitted = false  // tracks SELECT-list comma-newlines

        func appendNewline() {
            // Collapse trailing whitespace + ensure exactly one newline.
            while let last = output.last, last == " " { output.removeLast() }
            if !output.hasSuffix("\n") && !output.isEmpty { output.append("\n") }
        }
        func appendSpace() {
            if let last = output.last, last == " " || last == "\n" { return }
            output.append(" ")
        }

        while i < tokens.count {
            let tok = tokens[i]
            // Multi-word clause keywords win over their single-word
            // siblings (so `ORDER BY` doesn't fire as `order` then
            // `by`).
            if case .keyword(let kw) = tok.kind {
                if let (joined, consumed) = matchMultiWord(tokens, from: i, starting: kw) {
                    appendNewline()
                    output.append(joined.uppercased())
                    appendSpace()
                    i += consumed
                    firstColumnEmitted = false
                    continue
                }
                if singleWordClauses.contains(kw) {
                    appendNewline()
                    output.append(kw.uppercased())
                    appendSpace()
                    i += 1
                    if kw == "select" { firstColumnEmitted = false }
                    continue
                }
                // Non-clause keyword (AND, OR, AS, IS, NULL, …):
                // uppercase, keep inline.
                if kw == "and" || kw == "or" {
                    appendNewline()
                    output.append("  ")
                    output.append(kw.uppercased())
                    appendSpace()
                } else {
                    output.append(kw.uppercased())
                    appendSpace()
                }
                i += 1
                continue
            }

            // Commas in a SELECT projection: break to next line +
            // indent. Commas inside parens (function args) stay inline
            // — we approximate this by tracking paren depth.
            if case .punct(let c) = tok.kind, c == "," {
                if parenDepth(tokens: tokens, upTo: i) == 0 {
                    output.append(",")
                    appendNewline()
                    output.append("  ")
                    firstColumnEmitted = true
                    i += 1
                    continue
                }
                output.append(", ")
                i += 1
                continue
            }

            // Default: append the raw substring for anything else
            // (identifiers, strings, numbers, punctuation, operators).
            output.append(ns.substring(with: tok.range))
            // Heuristic spacer — don't add a trailing space if the next
            // token is punctuation that wants to hug.
            let nextWantsSpace = (i + 1 < tokens.count) ? wantsLeadingSpace(tokens[i + 1]) : false
            if nextWantsSpace { appendSpace() }
            i += 1
        }
        _ = firstColumnEmitted
        return output.trimmingCharacters(in: .whitespacesAndNewlines) + "\n"
    }

    // MARK: - Helpers

    private static func matchMultiWord(_ tokens: [SQLToken], from i: Int, starting kw: String) -> (joined: String, consumed: Int)? {
        for pattern in multiWordClauses where pattern.first == kw {
            if i + pattern.count > tokens.count { continue }
            var ok = true
            for (offset, word) in pattern.enumerated() {
                guard case .keyword(let next) = tokens[i + offset].kind, next == word else {
                    ok = false; break
                }
            }
            if ok {
                return (pattern.joined(separator: " "), pattern.count)
            }
        }
        return nil
    }

    private static func parenDepth(tokens: [SQLToken], upTo i: Int) -> Int {
        var depth = 0
        for k in 0..<i {
            if case .punct(let c) = tokens[k].kind {
                if c == "(" { depth += 1 }
                else if c == ")" { depth = max(0, depth - 1) }
            }
        }
        return depth
    }

    /// Whether the *previous* emit should hand off a trailing space.
    /// Open-paren / dot / comma close-paren shouldn't have one in
    /// front of them; everything else does.
    private static func wantsLeadingSpace(_ tok: SQLToken) -> Bool {
        if case .punct(let c) = tok.kind {
            return !(c == "(" || c == ")" || c == "," || c == ".")
        }
        if case .op(let s) = tok.kind, s == "." || s == "::" { return false }
        return true
    }
}
