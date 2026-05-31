import Foundation

/// Where the completion request is coming from. The notebook editor
/// hands us the raw text + caret so we can derive context; the
/// JetBrains-style WHERE / ORDER BY strip tells us up-front because it
/// already knows the bound table + which clause it is.
enum SQLCompletionContext {
    case scratchpad(fullText: String, caretIndex: Int)
    case clause(table: TableNode, kind: ClauseKind)
    /// A bare SQL value expression (the typed-input expression field). We
    /// don't have a FROM to parse, so the caller passes the columns that
    /// are in scope (the row being edited / the table) directly — those
    /// rank highest, then schema-wide functions + expression keywords.
    case expression(columns: [ColumnNode])

    enum ClauseKind { case whereExpr, orderBy }
}

/// Schema-aware completion source. Produces ranked `CompletionItem`s —
/// each carrying a kind (for the icon) and a detail string (column type /
/// function signature) so the custom completion panel can render
/// IDE-grade rows, not a bare string list.
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
    /// Common scalar functions + keywords worth surfacing inside a value
    /// expression. Parens included so picking one starts the call.
    private static let expressionBuiltins: [String] = [
        "now()", "current_date", "current_timestamp", "current_user",
        "gen_random_uuid()", "coalesce(", "nullif(", "greatest(", "least(",
        "lower(", "upper(", "trim(", "length(", "round(", "abs(", "floor(",
        "ceil(", "concat(", "substring(", "to_char(", "to_timestamp(",
        "date_trunc(", "extract(", "age(", "cast(",
        "CASE", "WHEN", "THEN", "ELSE", "END", "NULL", "TRUE", "FALSE",
    ]

    // MARK: - Public API

    /// Rich items for the custom completion panel.
    static func items(
        for partial: String,
        in schema: SchemaSnapshot,
        context: SQLCompletionContext
    ) -> [CompletionItem] {
        let needle = partial.lowercased()
        if needle.isEmpty {
            // Empty-needle: only useful right after a `name.` qualifier, or
            // in the expression field (⌘Space shows the whole set).
            switch context {
            case .scratchpad(let fullText, let caretIndex):
                let before = textBefore(caretIndex: caretIndex, in: fullText)
                if !insideStringOrComment(before), let qualifier = trailingQualifier(in: before) {
                    return rank(needle: "", candidates: qualifiedCandidates(qualifier: qualifier, schema: schema))
                }
                return []
            case .expression(let columns):
                return rank(needle: "", candidates: expressionCandidates(columns: columns, schema: schema))
            case .clause:
                return []
            }
        }
        let candidates: [Candidate]
        switch context {
        case .clause(let table, .whereExpr):
            candidates = clauseCandidates(table: table, kind: .whereExpr)
        case .clause(let table, .orderBy):
            candidates = clauseCandidates(table: table, kind: .orderBy)
        case .scratchpad(let fullText, let caretIndex):
            candidates = scratchpadCandidates(fullText: fullText, caretIndex: caretIndex, schema: schema)
        case .expression(let columns):
            candidates = expressionCandidates(columns: columns, schema: schema)
        }
        return rank(needle: needle, candidates: candidates)
    }

    /// Back-compat string API (native popups + any caller that only wants
    /// the values). Routes through the rich path and projects the values.
    static func completions(
        for partial: String,
        in schema: SchemaSnapshot,
        context: SQLCompletionContext
    ) -> [String] {
        items(for: partial, in: schema, context: context).map(\.value)
    }

    // MARK: - Clause-strip context (WHERE / ORDER BY on a known table)

    private static func clauseCandidates(table: TableNode, kind: SQLCompletionContext.ClauseKind) -> [Candidate] {
        var out: [Candidate] = []
        for col in table.columns {
            out.append(Candidate(value: col.name, weight: 3, kind: .column, detail: col.typeName))
        }
        switch kind {
        case .whereExpr:
            for kw in whereKeywords { out.append(Candidate(value: kw, weight: 2, kind: .keyword)) }
        case .orderBy:
            for kw in orderByKeywords { out.append(Candidate(value: kw, weight: 2, kind: .keyword)) }
        }
        return out
    }

    // MARK: - Expression context (bare value)

    /// Candidates for a bare value expression: in-scope columns first,
    /// then schema-wide functions + builtins. No statement to parse.
    private static func expressionCandidates(columns: [ColumnNode], schema: SchemaSnapshot) -> [Candidate] {
        var out: [Candidate] = []
        for col in columns {
            out.append(Candidate(value: col.name, weight: 5, kind: .column, detail: col.typeName))
        }
        out.append(contentsOf: functionCandidates(schema: schema, baseWeight: 2))
        for b in expressionBuiltins {
            let isKeyword = b == b.uppercased()
            out.append(Candidate(value: b, weight: 1, kind: isKeyword ? .keyword : .snippet))
        }
        return out
    }

    // MARK: - Scratchpad context (parse text before caret)

    private static func scratchpadCandidates(fullText: String, caretIndex: Int, schema: SchemaSnapshot) -> [Candidate] {
        let textBeforeCaret = textBefore(caretIndex: caretIndex, in: fullText)
        // Hard guard: never offer completions inside a string/comment.
        if insideStringOrComment(textBeforeCaret) { return [] }

        let scope = SQLScope.analyze(text: fullText, caretIndex: caretIndex)

        if let qualifier = scope.qualifier {
            return qualifiedCandidatesViaScope(qualifier: qualifier, scope: scope, schema: schema)
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
        return candidates
    }

    /// Function candidates emit BOTH bare-name and qualified-name strings.
    /// Dedup bare names across overloads; detail carries the signature.
    private static func functionCandidates(schema: SchemaSnapshot, baseWeight: Int) -> [Candidate] {
        var out: [Candidate] = []
        var seenBare = Set<String>()
        for sch in schema.schemas {
            for fn in sch.functions {
                let sig = fn.arguments.isEmpty ? "()" : fn.arguments
                let detail = fn.returnType.isEmpty ? sig : "\(sig) → \(fn.returnType)"
                if !seenBare.contains(fn.name) {
                    out.append(Candidate(value: fn.name, weight: baseWeight + 1, kind: .function, detail: detail))
                    seenBare.insert(fn.name)
                }
                out.append(Candidate(value: "\(sch.name).\(fn.name)", weight: baseWeight, kind: .function, detail: detail))
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

    private static func resolveInScopeTables(scope: SQLScope.Analysis, schema: SchemaSnapshot) -> Set<String> {
        var out = Set<String>()
        for ref in scope.references {
            if findTable(schemaName: ref.schema, tableName: ref.table, in: schema) != nil {
                out.insert(ref.table.lowercased())
            }
        }
        return out
    }

    private static func qualifiedCandidatesViaScope(qualifier: String, scope: SQLScope.Analysis, schema: SchemaSnapshot) -> [Candidate] {
        let needle = qualifier.lowercased()
        for ref in scope.references where ref.alias == needle {
            if let t = findTable(schemaName: ref.schema, tableName: ref.table, in: schema) {
                return t.columns.map { Candidate(value: $0.name, weight: 6, kind: .column, detail: $0.typeName) }
            }
        }
        if let sch = schema.schemas.first(where: { $0.name.lowercased() == needle }) {
            var out = sch.tables.map { Candidate(value: $0.name, weight: 5, kind: .table, detail: "table") }
            out.append(contentsOf: sch.functions.map {
                Candidate(value: $0.name, weight: 4, kind: .function, detail: $0.arguments)
            })
            return out
        }
        for sch in schema.schemas {
            if let t = sch.tables.first(where: { $0.name.lowercased() == needle }) {
                return t.columns.map { Candidate(value: $0.name, weight: 5, kind: .column, detail: $0.typeName) }
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
        for sch in schema.schemas {
            if let t = sch.tables.first(where: { $0.name.lowercased() == needle }) { return t }
        }
        return nil
    }

    // MARK: - Qualifier (`name.`) detection

    private static func trailingQualifier(in textBeforeCaret: String) -> String? {
        let ns = textBeforeCaret as NSString
        var i = ns.length
        while i > 0 {
            let c = ns.character(at: i - 1)
            if c == 0x20 || c == 0x09 || c == 0x0A { i -= 1 } else { break }
        }
        guard i > 0, ns.character(at: i - 1) == 0x2E /* . */ else { return nil }
        var end = i - 1
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
        if let sch = schema.schemas.first(where: { $0.name.compare(qualifier, options: .caseInsensitive) == .orderedSame }) {
            for table in sch.tables {
                out.append(Candidate(value: table.name, weight: 5, kind: .table, detail: "table"))
            }
            for fn in sch.functions {
                out.append(Candidate(value: fn.name, weight: 4, kind: .function, detail: fn.arguments))
            }
            return out
        }
        for sch in schema.schemas {
            if let table = sch.tables.first(where: { $0.name.compare(qualifier, options: .caseInsensitive) == .orderedSame }) {
                for col in table.columns {
                    out.append(Candidate(value: col.name, weight: 5, kind: .column, detail: col.typeName))
                }
            }
        }
        return out
    }

    // MARK: - Context-keyword detection

    private enum ContextKind { case table, column, orderBy, general }

    // MARK: - Candidate generators

    private static func tableCandidates(schema: SchemaSnapshot, baseWeight: Int) -> [Candidate] {
        var out: [Candidate] = []
        for sch in schema.schemas {
            for table in sch.tables {
                let kind: CompletionItem.Kind = table.kind == .view || table.kind == .materializedView ? .view : .table
                out.append(Candidate(value: table.name, weight: baseWeight + 1, kind: kind, detail: kind.categoryLabel))
                out.append(Candidate(value: "\(sch.name).\(table.name)", weight: baseWeight, kind: kind, detail: "\(sch.name)"))
            }
        }
        return out
    }

    private static func schemaCandidates(schema: SchemaSnapshot, baseWeight: Int) -> [Candidate] {
        schema.schemas.map { Candidate(value: $0.name, weight: baseWeight, kind: .schema, detail: "schema") }
    }

    private static func columnCandidates(schema: SchemaSnapshot, prioritised: Set<String>) -> [Candidate] {
        var seen = Set<String>()
        var out: [Candidate] = []
        for sch in schema.schemas {
            for table in sch.tables {
                let inScope = prioritised.contains(table.name.lowercased())
                for col in table.columns {
                    if seen.contains(col.name) { continue }
                    seen.insert(col.name)
                    let weight = inScope ? 4 : (prioritised.isEmpty ? 2 : 1)
                    out.append(Candidate(value: col.name, weight: weight, kind: .column, detail: col.typeName))
                }
            }
        }
        return out
    }

    private static func keywordCandidates(_ words: [String], weight: Int) -> [Candidate] {
        words.map { Candidate(value: $0, weight: weight, kind: .keyword) }
    }

    // MARK: - Ranking

    private struct Candidate {
        let value: String
        let weight: Int
        let kind: CompletionItem.Kind
        var detail: String? = nil
    }

    private static func item(from c: Candidate) -> CompletionItem {
        CompletionItem(value: c.value, detail: c.detail ?? c.kind.categoryLabel, kind: c.kind)
    }

    /// Score: prefix wins big, substring still counts. Weight nudges the
    /// order so context-matched suggestions stay on top. Empty needle = no
    /// filter, sort by weight then alpha.
    private static func rank(needle: String, candidates: [Candidate]) -> [CompletionItem] {
        if needle.isEmpty {
            return candidates
                .sorted { a, b in
                    if a.weight != b.weight { return a.weight > b.weight }
                    return a.value.localizedCaseInsensitiveCompare(b.value) == .orderedAscending
                }
                .prefix(60)
                .map(item(from:))
        }
        var scored: [(score: Int, c: Candidate)] = []
        for c in candidates {
            let h = c.value.lowercased()
            let base: Int
            if h == needle { base = 200 }
            else if h.hasPrefix(needle) { base = 120 }
            else if h.contains(needle) { base = 50 }
            else if fuzzyMatches(needle: needle, haystack: h) { base = 30 }
            else { continue }
            let len = c.value.count
            scored.append((base + c.weight * 5 - len / 8, c))
        }
        return scored
            .sorted { a, b in
                if a.score != b.score { return a.score > b.score }
                return a.c.value.localizedCaseInsensitiveCompare(b.c.value) == .orderedAscending
            }
            .prefix(40)
            .map { item(from: $0.c) }
    }

    /// In-order subsequence test (`gru` matches `gen_random_uuid`). Cheap
    /// fuzzy fallback below exact/prefix/substring so good matches still
    /// outrank scattered ones.
    private static func fuzzyMatches(needle: String, haystack: String) -> Bool {
        var ni = needle.startIndex
        for ch in haystack {
            if ni == needle.endIndex { break }
            if ch == needle[ni] { ni = needle.index(after: ni) }
        }
        return ni == needle.endIndex
    }

    // MARK: - Helpers

    private static func textBefore(caretIndex: Int, in text: String) -> String {
        let ns = text as NSString
        let clamped = max(0, min(caretIndex, ns.length))
        return ns.substring(to: clamped)
    }

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
                    if i + 1 < n && chars[i + 1] == "'" { i += 2; continue }
                    inString = false; i += 1; continue
                }
                i += 1; continue
            }
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
}
