import Foundation

/// DataGrip-style `:name` query parameters for the scratchpad. Before a
/// statement runs, `names(in:)` finds the distinct placeholders so the UI can
/// prompt for values, then `substitute(_:with:)` splices the user-supplied raw
/// SQL in their place.
///
/// The scan is lexical, not a full parser, but it is careful about the three
/// places a `:` must NOT start a parameter:
///   - inside a string literal (`'…'`, with `''` escape) or dollar-quoted body
///   - inside a line (`-- …`) or block (`/* … */`) comment
///   - the `::type` cast operator (two colons)
///
/// A parameter name is `:` followed by an identifier (`[A-Za-z_][A-Za-z0-9_]*`).
enum ScratchpadParameters {

    /// Distinct placeholder names (without the leading `:`), in first-seen
    /// order. `SELECT * FROM t WHERE id = :id AND owner = :owner` → `["id","owner"]`.
    static func names(in sql: String) -> [String] {
        var seen = Set<String>()
        var out: [String] = []
        scan(sql) { name, _ in
            if !seen.contains(name) { seen.insert(name); out.append(name) }
        }
        return out
    }

    /// Replace each `:name` with `values[name]` (raw SQL — the caller decides
    /// quoting). Names absent from `values` are left untouched, so a partially
    /// filled set still produces runnable-or-clearly-incomplete SQL.
    static func substitute(_ sql: String, with values: [String: String]) -> String {
        // Collect replacement ranges first, then apply back-to-front so earlier
        // offsets stay valid.
        var hits: [(range: Range<Int>, name: String)] = []
        scan(sql) { name, range in hits.append((range, name)) }
        guard !hits.isEmpty else { return sql }

        var chars = Array(sql)
        for hit in hits.reversed() {
            guard let replacement = values[hit.name] else { continue }
            chars.replaceSubrange(hit.range, with: Array(replacement))
        }
        return String(chars)
    }

    /// Walk `sql` once, invoking `found(name, range)` for every `:name`
    /// placeholder outside strings/comments. `range` covers the whole
    /// `:name` span (including the leading colon) as character offsets.
    private static func scan(_ sql: String, found: (String, Range<Int>) -> Void) {
        let chars = Array(sql)
        let n = chars.count
        var i = 0
        var inString = false       // '…'
        var inLine = false         // -- …
        var inBlock = false        // /* … */
        var dollarTag: String? = nil   // $tag$ … $tag$

        func isIdentStart(_ c: Character) -> Bool { c == "_" || c.isLetter }
        func isIdentChar(_ c: Character) -> Bool { c == "_" || c.isLetter || c.isNumber }

        while i < n {
            let c = chars[i]

            if inLine {
                if c == "\n" { inLine = false }
                i += 1; continue
            }
            if inBlock {
                if c == "*", i + 1 < n, chars[i + 1] == "/" { inBlock = false; i += 2; continue }
                i += 1; continue
            }
            if inString {
                if c == "'" {
                    if i + 1 < n, chars[i + 1] == "'" { i += 2; continue }   // '' escape
                    inString = false
                }
                i += 1; continue
            }
            if let tag = dollarTag {
                if c == "$", matchesTag(chars, at: i, tag: tag) { dollarTag = nil; i += tag.count; continue }
                i += 1; continue
            }

            // Not in any quoted/comment context.
            if c == "'" { inString = true; i += 1; continue }
            if c == "-", i + 1 < n, chars[i + 1] == "-" { inLine = true; i += 2; continue }
            if c == "/", i + 1 < n, chars[i + 1] == "*" { inBlock = true; i += 2; continue }
            if c == "$", let tag = readDollarTag(chars, at: i) { dollarTag = tag; i += tag.count; continue }

            if c == ":" {
                // `::` cast — emit nothing, skip both colons.
                if i + 1 < n, chars[i + 1] == ":" { i += 2; continue }
                // `:name` — read the identifier.
                if i + 1 < n, isIdentStart(chars[i + 1]) {
                    var j = i + 1
                    while j < n, isIdentChar(chars[j]) { j += 1 }
                    let name = String(chars[(i + 1)..<j])
                    found(name, i..<j)
                    i = j; continue
                }
            }
            i += 1
        }
    }

    /// If a dollar-quote opener (`$$` or `$tag$`) starts at `i`, return the tag
    /// text (e.g. `$$` or `$tag$`); else nil.
    private static func readDollarTag(_ chars: [Character], at i: Int) -> String? {
        let n = chars.count
        guard chars[i] == "$" else { return nil }
        var j = i + 1
        while j < n, chars[j] != "$" {
            let c = chars[j]
            guard c == "_" || c.isLetter || c.isNumber else { return nil }
            j += 1
        }
        guard j < n, chars[j] == "$" else { return nil }
        return String(chars[i...j])
    }

    private static func matchesTag(_ chars: [Character], at i: Int, tag: String) -> Bool {
        let t = Array(tag)
        guard i + t.count <= chars.count else { return false }
        for k in 0..<t.count where chars[i + k] != t[k] { return false }
        return true
    }
}
