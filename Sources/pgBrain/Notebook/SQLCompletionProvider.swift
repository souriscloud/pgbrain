import Foundation

/// Where the completion request is coming from. The notebook editor
/// hands us the raw text + caret so we can derive context; the
/// JetBrains-style WHERE / ORDER BY strip tells us up-front because it
/// already knows the bound table + which clause it is.
enum SQLCompletionContext {
    case scratchpad(fullText: String, caretIndex: Int)
    case clause(table: TableNode, kind: ClauseKind)

    enum ClauseKind { case whereExpr, orderBy }
}

/// Schema-aware completion source. v2: context-aware ranking — we look
/// at what's before the partial-word (a `.` qualifier, or the most
/// recent SQL keyword) and decide whether to surface tables, columns,
/// or both. Eliminates the v1 "every keyword and column always" noise.
@MainActor
enum SQLCompletionProvider {
    private static let whereKeywords: [String] = [
        "AND", "OR", "NOT", "IS NULL", "IS NOT NULL",
        "IN", "BETWEEN", "LIKE", "ILIKE", "SIMILAR TO",
        "EXISTS", "ANY", "ALL",
        "TRUE", "FALSE", "NULL",
    ]
    private static let orderByKeywords: [String] = [
        "ASC", "DESC", "NULLS FIRST", "NULLS LAST",
    ]
    private static let queryKeywords: [String] = [
        "SELECT", "FROM", "WHERE", "GROUP BY", "HAVING", "ORDER BY",
        "LIMIT", "OFFSET", "JOIN", "LEFT JOIN", "RIGHT JOIN",
        "INNER JOIN", "FULL JOIN", "CROSS JOIN", "ON", "USING",
        "WITH", "WITH RECURSIVE", "RETURNING", "DISTINCT", "AS",
        "UNION", "UNION ALL", "INTERSECT", "EXCEPT",
        "CASE", "WHEN", "THEN", "ELSE", "END",
        "AND", "OR", "NOT",
    ]
    private static let dmlKeywords: [String] = [
        "INSERT INTO", "VALUES", "UPDATE", "SET", "DELETE FROM",
        "TRUNCATE", "CREATE TABLE", "CREATE INDEX", "CREATE VIEW",
        "DROP TABLE", "ALTER TABLE",
        "BEGIN", "COMMIT", "ROLLBACK", "SAVEPOINT",
    ]

    static func completions(
        for partial: String,
        in schema: SchemaSnapshot,
        context: SQLCompletionContext
    ) -> [String] {
        let needle = partial.lowercased()
        // Empty-needle path: still useful when the caret is right after
        // a `name.` qualifier (`SELECT users.|`) — return the
        // qualifier's children without a substring filter so the popup
        // can show the full column list.
        if needle.isEmpty {
            if case .scratchpad(let fullText, let caretIndex) = context {
                let textBeforeCaret = textBefore(caretIndex: caretIndex, in: fullText)
                if !insideStringOrComment(textBeforeCaret),
                   let qualifier = trailingQualifier(in: textBeforeCaret) {
                    return rank(needle: "", candidates: qualifiedCandidates(qualifier: qualifier, schema: schema))
                }
            }
            return []
        }
        switch context {
        case .clause(let table, .whereExpr):
            return rank(needle: needle, candidates: clauseCandidates(table: table, kind: .whereExpr))
        case .clause(let table, .orderBy):
            return rank(needle: needle, candidates: clauseCandidates(table: table, kind: .orderBy))
        case .scratchpad(let fullText, let caretIndex):
            return scratchpadCompletions(needle: needle, fullText: fullText, caretIndex: caretIndex, schema: schema)
        }
    }

    // MARK: - Clause-strip context (WHERE / ORDER BY on a known table)

    private static func clauseCandidates(table: TableNode, kind: SQLCompletionContext.ClauseKind) -> [Candidate] {
        var out: [Candidate] = []
        // This-table columns get the highest weight because that's
        // almost always what the user is typing.
        for col in table.columns {
            out.append(Candidate(value: col.name, weight: 3, category: .column))
        }
        switch kind {
        case .whereExpr:
            for kw in whereKeywords { out.append(Candidate(value: kw, weight: 2, category: .keyword)) }
        case .orderBy:
            for kw in orderByKeywords { out.append(Candidate(value: kw, weight: 2, category: .keyword)) }
        }
        return out
    }

    // MARK: - Scratchpad context (parse text before caret)

    private static func scratchpadCompletions(needle: String, fullText: String, caretIndex: Int, schema: SchemaSnapshot) -> [String] {
        let textBeforeCaret = textBefore(caretIndex: caretIndex, in: fullText)
        // Hard guard: never offer completions when the caret is inside
        // a string literal, line comment, or block comment — that's
        // user-content territory and a popup there destroys typed text.
        if insideStringOrComment(textBeforeCaret) { return [] }

        // Token-driven scope analysis (replaces the old regex/substring
        // detector). The scope knows what tables are referenced *in
        // this statement*, their aliases, the active clause keyword,
        // and the qualifier touching the caret if any.
        let scope = SQLScope.analyze(text: fullText, caretIndex: caretIndex)

        // Qualifier path: `alias.|` → that table's columns. `schema.|`
        // → that schema's tables + functions. Also handles raw
        // `tablename.|`.
        if let qualifier = scope.qualifier {
            return rank(needle: needle,
                        candidates: qualifiedCandidatesViaScope(qualifier: qualifier,
                                                                scope: scope,
                                                                schema: schema))
        }

        let kind = mapScopeKind(scope.context)
        let inScope = resolveInScopeTables(scope: scope, schema: schema)

        var candidates: [Candidate] = []
        switch kind {
        case .table:
            candidates.append(contentsOf: tableCandidates(schema: schema, baseWeight: 3))
            candidates.append(contentsOf: schemaCandidates(schema: schema, baseWeight: 1))
        case .column:
            candidates.append(contentsOf: columnCandidates(schema: schema, prioritised: inScope))
            // SELECT clauses and WHERE expressions can both call
            // functions inline, so surface UDFs alongside columns.
            candidates.append(contentsOf: functionCandidates(schema: schema, baseWeight: 2))
            candidates.append(contentsOf: keywordCandidates(whereKeywords, weight: 1))
        case .orderBy:
            candidates.append(contentsOf: columnCandidates(schema: schema, prioritised: inScope))
            candidates.append(contentsOf: functionCandidates(schema: schema, baseWeight: 1))
            candidates.append(contentsOf: keywordCandidates(orderByKeywords, weight: 2))
        case .general:
            candidates.append(contentsOf: keywordCandidates(queryKeywords, weight: 2))
            candidates.append(contentsOf: keywordCandidates(dmlKeywords, weight: 1))
            candidates.append(contentsOf: tableCandidates(schema: schema, baseWeight: 1))
            candidates.append(contentsOf: functionCandidates(schema: schema, baseWeight: 1))
        }
        return rank(needle: needle, candidates: candidates)
    }

    /// Function candidates emit BOTH bare-name and qualified-name
    /// strings, just like tables. Dedup across overloads — the popup
    /// shouldn't list `myfunc` five times because there are five
    /// signatures.
    private static func functionCandidates(schema: SchemaSnapshot, baseWeight: Int) -> [Candidate] {
        var out: [Candidate] = []
        var seenBare = Set<String>()
        for sch in schema.schemas {
            for fn in sch.functions {
                if !seenBare.contains(fn.name) {
                    out.append(Candidate(value: fn.name, weight: baseWeight + 1, category: .keyword))
                    seenBare.insert(fn.name)
                }
                out.append(Candidate(value: "\(sch.name).\(fn.name)", weight: baseWeight, category: .keyword))
            }
        }
        return out
    }

    // MARK: - Scope adapters

    private static func mapScopeKind(_ kind: SQLScope.ContextKind) -> ContextKind {
        switch kind {
        case .table:    return .table
        case .column:   return .column
        case .orderBy:  return .orderBy
        case .general:  return .general
        }
    }

    /// Resolve every `TableRef` in scope to a concrete `TableNode`
    /// (when present in the schema). Used both to bias column
    /// suggestions toward referenced tables AND to resolve aliases for
    /// `alias.` qualifiers.
    private static func resolveInScopeTables(scope: SQLScope.Analysis, schema: SchemaSnapshot) -> Set<String> {
        var out = Set<String>()
        for ref in scope.references {
            if let _ = findTable(schemaName: ref.schema, tableName: ref.table, in: schema) {
                out.insert(ref.table.lowercased())
            }
        }
        return out
    }

    /// `qualifier.|` resolution. Order:
    ///   1. `qualifier` matches an in-scope alias → that table's columns
    ///   2. `qualifier` matches a schema → that schema's tables + functions
    ///   3. `qualifier` matches a bare table name → that table's columns
    private static func qualifiedCandidatesViaScope(qualifier: String, scope: SQLScope.Analysis, schema: SchemaSnapshot) -> [Candidate] {
        let needle = qualifier.lowercased()
        // 1) Alias.
        for ref in scope.references where ref.alias == needle {
            if let t = findTable(schemaName: ref.schema, tableName: ref.table, in: schema) {
                return t.columns.map { Candidate(value: $0.name, weight: 6, category: .column) }
            }
        }
        // 2) Schema.
        if let sch = schema.schemas.first(where: { $0.name.lowercased() == needle }) {
            var out = sch.tables.map { Candidate(value: $0.name, weight: 5, category: .table) }
            out.append(contentsOf: sch.functions.map {
                Candidate(value: $0.name, weight: 4, category: .keyword)
            })
            return out
        }
        // 3) Bare table name.
        for sch in schema.schemas {
            if let t = sch.tables.first(where: { $0.name.lowercased() == needle }) {
                return t.columns.map { Candidate(value: $0.name, weight: 5, category: .column) }
            }
        }
        return []
    }

    private static func findTable(schemaName: String?, tableName: String, in schema: SchemaSnapshot) -> TableNode? {
        let needle = tableName.lowercased()
        if let sname = schemaName?.lowercased() {
            return schema.schemas
                .first(where: { $0.name.lowercased() == sname })?
                .tables.first(where: { $0.name.lowercased() == needle })
        }
        // Unqualified: first table that matches anywhere.
        for sch in schema.schemas {
            if let t = sch.tables.first(where: { $0.name.lowercased() == needle }) { return t }
        }
        return nil
    }

    // MARK: - Qualifier (`name.`) detection — legacy, kept for now

    /// Returns the identifier immediately followed by a literal `.`
    /// before the partial word (e.g. for `users.` in
    /// `SELECT users.name FROM …`, qualifier = "users"). Walks backward
    /// from `caret - partial.count` so the partial itself doesn't count.
    private static func trailingQualifier(in textBeforeCaret: String) -> String? {
        let ns = textBeforeCaret as NSString
        var i = ns.length
        // The partial word has already been split off by the caller;
        // textBeforeCaret holds everything *before* the partial, which
        // means the qualifier+dot (if any) is the LAST two tokens.
        // Walk back through whitespace.
        while i > 0 {
            let c = ns.character(at: i - 1)
            if c == 0x20 || c == 0x09 || c == 0x0A { i -= 1 } else { break }
        }
        guard i > 0, ns.character(at: i - 1) == 0x2E /* . */ else { return nil }
        // Skip the dot.
        var end = i - 1
        // Identifier characters (incl. quoted form). We don't fully
        // parse quoted identifiers — bare names are 99% of usage.
        var start = end
        while start > 0 {
            let c = ns.character(at: start - 1)
            if isIdentChar(c) { start -= 1 } else { break }
        }
        guard start < end else { return nil }
        return ns.substring(with: NSRange(location: start, length: end - start))
    }

    private static func qualifiedCandidates(qualifier: String, schema: SchemaSnapshot) -> [Candidate] {
        var out: [Candidate] = []
        // Schema match → tables + functions in that schema.
        if let sch = schema.schemas.first(where: { $0.name.compare(qualifier, options: .caseInsensitive) == .orderedSame }) {
            for table in sch.tables {
                out.append(Candidate(value: table.name, weight: 5, category: .table))
            }
            for fn in sch.functions {
                out.append(Candidate(value: fn.name, weight: 4, category: .keyword))
            }
            return out
        }
        // Table match (across schemas, but disambiguate on duplicate
        // names by qualifying — last one wins, fine for v1).
        for sch in schema.schemas {
            if let table = sch.tables.first(where: { $0.name.compare(qualifier, options: .caseInsensitive) == .orderedSame }) {
                for col in table.columns {
                    out.append(Candidate(value: col.name, weight: 5, category: .column))
                }
            }
        }
        return out
    }

    // MARK: - Context-keyword detection

    private enum ContextKind { case table, column, orderBy, general }

    /// Walks the lowercased text backward and returns the kind of
    /// completions most recent SQL context calls for. We only care
    /// about a small set of keywords — the rest implicitly stay
    /// `.general`. Assumes `loweredText` is already padded with
    /// whitespace on both ends so word-boundary patterns match
    /// regardless of where the keyword sits.
    private static func mostRecentKeywordKind(in loweredText: String) -> ContextKind {
        // Order matters — "order by" must beat the trailing "by" alone.
        let tableKeywords = [" from ", " join ", " into ", " update ", " table ", " references ", " delete from "]
        let columnKeywords = [" where ", " and ", " or ", " on ", " set ", " having ", " returning ", " select "]
        let orderByKeywords = [" order by ", " group by "]

        // Find the rightmost occurrence among the bundles.
        var best: (range: Range<String.Index>, kind: ContextKind)?
        func consider(_ words: [String], kind: ContextKind) {
            for w in words {
                if let r = loweredText.range(of: w, options: [.backwards]) {
                    if best == nil || r.upperBound > best!.range.upperBound {
                        best = (r, kind)
                    }
                }
            }
        }
        consider(orderByKeywords, kind: .orderBy)
        consider(tableKeywords, kind: .table)
        consider(columnKeywords, kind: .column)
        return best?.kind ?? .general
    }

    /// Extract identifiers following FROM / JOIN / UPDATE / INTO so
    /// column suggestions can prefer columns from referenced tables.
    /// Assumes `loweredText` is already space-padded.
    private static func inScopeTables(in loweredText: String, schema: SchemaSnapshot) -> Set<String> {
        var result = Set<String>()
        let scanners = [" from ", " join ", " update ", " into "]
        let lookup = Dictionary(grouping: schema.schemas.flatMap { sch in sch.tables.map { ($0.name.lowercased(), $0) } },
                                by: { $0.0 })
        for kw in scanners {
            var search = loweredText.startIndex..<loweredText.endIndex
            while let range = loweredText.range(of: kw, range: search) {
                // Pull the next identifier after the keyword.
                var i = range.upperBound
                while i < loweredText.endIndex, loweredText[i].isWhitespace { i = loweredText.index(after: i) }
                let start = i
                while i < loweredText.endIndex, isIdentChar(loweredText[i].unicodeScalars.first?.value ?? 0) || loweredText[i] == "." {
                    i = loweredText.index(after: i)
                }
                if start < i {
                    let tok = String(loweredText[start..<i])
                    // Strip schema. prefix if any.
                    let bare = tok.split(separator: ".").last.map(String.init) ?? tok
                    if lookup[bare] != nil { result.insert(bare) }
                }
                search = i..<loweredText.endIndex
            }
        }
        return result
    }

    // MARK: - Candidate generators

    private static func tableCandidates(schema: SchemaSnapshot, baseWeight: Int) -> [Candidate] {
        var out: [Candidate] = []
        for sch in schema.schemas {
            for table in sch.tables {
                out.append(Candidate(value: table.name, weight: baseWeight + 1, category: .table))
                out.append(Candidate(value: "\(sch.name).\(table.name)", weight: baseWeight, category: .table))
            }
        }
        return out
    }

    private static func schemaCandidates(schema: SchemaSnapshot, baseWeight: Int) -> [Candidate] {
        schema.schemas.map { Candidate(value: $0.name, weight: baseWeight, category: .schema) }
    }

    private static func columnCandidates(schema: SchemaSnapshot, prioritised: Set<String>) -> [Candidate] {
        var seen = Set<String>()
        var out: [Candidate] = []
        for sch in schema.schemas {
            for table in sch.tables {
                let inScope = prioritised.contains(table.name.lowercased())
                for col in table.columns {
                    // Dedup column names across tables to avoid 50
                    // entries of `id`. Suggest each name once,
                    // weighted by whether its table is in scope.
                    if seen.contains(col.name) { continue }
                    seen.insert(col.name)
                    let weight = inScope ? 4 : (prioritised.isEmpty ? 2 : 1)
                    out.append(Candidate(value: col.name, weight: weight, category: .column))
                }
            }
        }
        return out
    }

    private static func keywordCandidates(_ words: [String], weight: Int) -> [Candidate] {
        words.map { Candidate(value: $0, weight: weight, category: .keyword) }
    }

    // MARK: - Ranking

    private struct Candidate {
        enum Category { case keyword, schema, table, column }
        let value: String
        let weight: Int
        let category: Category
    }

    /// Score: prefix wins big, substring still counts. Weight nudges
    /// the order so this-table columns / context-matched suggestions
    /// stay on top. Empty needle = no filter, sort by weight then alpha.
    private static func rank(needle: String, candidates: [Candidate]) -> [String] {
        if needle.isEmpty {
            return candidates
                .sorted { a, b in
                    if a.weight != b.weight { return a.weight > b.weight }
                    return a.value.localizedCaseInsensitiveCompare(b.value) == .orderedAscending
                }
                .prefix(60)
                .map(\.value)
        }
        var scored: [(score: Int, value: String)] = []
        for c in candidates {
            let h = c.value.lowercased()
            let base: Int
            if h == needle { base = 200 }
            else if h.hasPrefix(needle) { base = 120 }
            else if h.contains(needle) { base = 50 }
            else { continue }
            // Shorter haystacks beat longer ones at the same base.
            let len = c.value.count
            scored.append((base + c.weight * 5 - len / 8, c.value))
        }
        return scored
            .sorted { a, b in
                if a.score != b.score { return a.score > b.score }
                return a.value.localizedCaseInsensitiveCompare(b.value) == .orderedAscending
            }
            .prefix(40)
            .map(\.value)
    }

    // MARK: - Helpers

    private static func textBefore(caretIndex: Int, in text: String) -> String {
        let ns = text as NSString
        let clamped = max(0, min(caretIndex, ns.length))
        return ns.substring(to: clamped)
    }

    /// Lightweight check: walk forward through the text and track
    /// whether the position right before the caret is inside a string
    /// literal (`'…'`, with `''` escape), a line comment (`-- … \n`),
    /// or a block comment (`/* … */`). Returns true if the caret sits
    /// inside any of those.
    private static func insideStringOrComment(_ textBeforeCaret: String) -> Bool {
        let chars = Array(textBeforeCaret.unicodeScalars)
        let n = chars.count
        var i = 0
        var inString = false
        var inLineComment = false
        var inBlockComment = false
        while i < n {
            let c = chars[i]
            if inLineComment {
                if c == "\n" { inLineComment = false }
                i += 1; continue
            }
            if inBlockComment {
                if c == "*" && i + 1 < n && chars[i + 1] == "/" {
                    inBlockComment = false; i += 2; continue
                }
                i += 1; continue
            }
            if inString {
                if c == "'" {
                    // Escaped '' stays in string.
                    if i + 1 < n && chars[i + 1] == "'" { i += 2; continue }
                    inString = false; i += 1; continue
                }
                i += 1; continue
            }
            // Not in any context — look for openers.
            if c == "'" { inString = true; i += 1; continue }
            if c == "-" && i + 1 < n && chars[i + 1] == "-" { inLineComment = true; i += 2; continue }
            if c == "/" && i + 1 < n && chars[i + 1] == "*" { inBlockComment = true; i += 2; continue }
            i += 1
        }
        return inString || inLineComment || inBlockComment
    }

    private static func isIdentChar(_ c: unichar) -> Bool {
        (c >= 0x41 && c <= 0x5A) || (c >= 0x61 && c <= 0x7A) ||
        (c >= 0x30 && c <= 0x39) || c == 0x5F
    }
    private static func isIdentChar(_ v: UInt32) -> Bool {
        (v >= 0x41 && v <= 0x5A) || (v >= 0x61 && v <= 0x7A) ||
        (v >= 0x30 && v <= 0x39) || v == 0x5F
    }
}
