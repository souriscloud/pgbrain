import Foundation

/// Static classification of a single SQL statement for the "you're about to
/// hose production" guardrail, and for `QueryRunner`'s choice between the
/// streaming read path (which appends `LIMIT`) and the materialised write
/// path. Deliberately permissive — false positives are cheap (a confirm
/// dialog / a materialised result), false negatives expensive (an unscoped
/// DELETE hitting prod, or a data-modifying CTE silently truncated by LIMIT).
/// Tokenised through the shared `SQLLexer`, so `--`, `E'…'`, dollar quotes
/// and quoted identifiers don't fool it.
enum SQLSafety {
    enum Verdict: Equatable {
        case readOnly
        case write                  // INSERT/UPDATE/DELETE/etc with a WHERE clause
        case destructiveUnscoped   // UPDATE/DELETE/TRUNCATE without WHERE
        case ddl                    // DROP/ALTER/TRUNCATE — always confirm on prod

        fileprivate var severity: Int {
            switch self {
            case .readOnly: 0
            case .write: 1
            case .destructiveUnscoped: 2
            case .ddl: 3
            }
        }
    }

    private static let ddlVerbs: Set<String> = [
        "drop", "alter", "create", "grant", "revoke", "vacuum", "reindex",
        "cluster", "comment", "refresh", "security", "reassign", "import",
    ]
    private static let dmlVerbs: Set<String> = ["insert", "update", "delete", "merge"]
    /// A DML keyword right after one of these is part of a clause, not a
    /// statement: `FOR [NO KEY] UPDATE`, `ON CONFLICT DO UPDATE`,
    /// `MERGE … THEN DELETE`, `ON DELETE CASCADE`, `x AS update`.
    private static let nonStatementPredecessors: Set<String> = ["for", "key", "do", "then", "on", "or", "as"]

    fileprivate struct Tok {
        let word: String?     // lowercased, bare words only
        let punct: UInt16     // 0 unless punctuation
        let depth: Int        // paren depth *outside* this token
    }

    static func classify(_ statement: String) -> Verdict {
        let toks = significantTokens(statement)
        return classify(toks, from: 0)
    }

    private static func classify(_ toks: [Tok], from start: Int) -> Verdict {
        // Empty / comment-only / bare `;` → nothing runs.
        guard let firstIdx = toks[start...].firstIndex(where: { $0.punct != 0x28 && $0.punct != 0x3B }) else {
            return .readOnly
        }
        // A leading non-word (quoted identifier, operator) isn't a statement we
        // recognise — don't wave it through as a read.
        guard let first = toks[firstIdx].word else { return .write }

        switch first {
        case "select", "values", "table", "with":
            return classifyQuery(toks, verbAt: firstIdx)
        case "show":
            return .readOnly
        case "explain":
            return classifyExplain(toks, at: firstIdx)
        case "insert", "merge":
            return max(.write, embeddedMutations(toks, from: firstIdx + 1))
        case "update", "delete":
            return max(scopedVerdict(toks, verbAt: firstIdx), embeddedMutations(toks, from: firstIdx + 1))
        case "truncate":
            return .destructiveUnscoped
        default:
            // DDL/maintenance verbs are always confirmed; everything else we
            // don't positively know to be a read (SET, LOCK, COPY, CALL, DO,
            // BEGIN, NOTIFY, …) is a write so it is never auto-LIMITed.
            return ddlVerbs.contains(first) ? .ddl : .write
        }
    }

    /// SELECT / VALUES / TABLE / WITH. Read-only unless it contains a
    /// data-modifying CTE or is a `SELECT … INTO new_table`.
    ///
    /// `SELECT … FOR UPDATE/SHARE` deliberately stays `.readOnly`: it only
    /// takes row locks, and QueryRunner's appended `LIMIT n` is valid after a
    /// locking clause (PG accepts `FOR UPDATE LIMIT n` and `LIMIT n FOR
    /// UPDATE`), so the auto-limit neither breaks nor truncates anything that
    /// is written.
    private static func classifyQuery(_ toks: [Tok], verbAt v: Int) -> Verdict {
        let base = toks[v].depth
        var mainIdx = v
        if toks[v].word == "with" {
            // Main statement = first top-level DML/query verb after the CTE list.
            guard let m = toks[(v + 1)...].firstIndex(where: {
                $0.depth == base && ($0.word.map { ["select", "values", "table", "insert", "update", "delete", "merge"].contains($0) } ?? false)
            }) else { return max(.write, embeddedMutations(toks, from: v + 1)) }
            mainIdx = m
        }
        var verdict = embeddedMutations(toks, from: v + 1, skipping: mainIdx)
        switch toks[mainIdx].word {
        case "insert", "merge":
            verdict = max(verdict, .write)
        case "update", "delete":
            verdict = max(verdict, scopedVerdict(toks, verbAt: mainIdx))
        default:
            // SELECT … INTO creates a table: DDL, and must never be LIMITed.
            let createsTable = toks[(mainIdx + 1)...].contains { $0.depth == base && $0.word == "into" }
            if createsTable { verdict = max(verdict, .ddl) }
        }
        return verdict
    }

    /// Plain EXPLAIN only plans; EXPLAIN ANALYZE executes the statement.
    private static func classifyExplain(_ toks: [Tok], at e: Int) -> Verdict {
        let inner: Set<String> = ["select", "values", "table", "with", "insert", "update",
                                  "delete", "merge", "create", "execute", "declare"]
        guard let innerIdx = toks[(e + 1)...].firstIndex(where: {
            $0.depth == toks[e].depth && ($0.word.map { inner.contains($0) } ?? false)
        }) else { return .readOnly }
        let analyzes = toks[(e + 1)..<innerIdx].contains { $0.word == "analyze" || $0.word == "analyse" }
        return analyzes ? classify(toks, from: innerIdx) : .readOnly
    }

    /// Worst verdict among DML verbs nested anywhere after `start` (CTEs,
    /// sub-statements). `skipping` excludes the main verb handled by the caller.
    private static func embeddedMutations(_ toks: [Tok], from start: Int, skipping: Int? = nil) -> Verdict {
        var verdict = Verdict.readOnly
        var i = start
        while i < toks.count {
            defer { i += 1 }
            guard i != skipping, let w = toks[i].word, dmlVerbs.contains(w) else { continue }
            if let prev = previousWord(toks, before: i), nonStatementPredecessors.contains(prev) { continue }
            if i > 0, toks[i - 1].punct == 0x2E { continue }                 // qualified name x.update
            if i + 1 < toks.count, toks[i + 1].punct == 0x2E { continue }   // update.col
            switch w {
            case "update", "delete": verdict = max(verdict, scopedVerdict(toks, verbAt: i))
            default: verdict = max(verdict, .write)
            }
        }
        return verdict
    }

    /// An UPDATE/DELETE is scoped when a WHERE appears at its own paren depth
    /// before its sub-statement ends — so a WHERE inside a scalar subquery
    /// (`UPDATE t SET x = (SELECT … WHERE …)`) or in the outer query of a CTE
    /// doesn't count.
    private static func scopedVerdict(_ toks: [Tok], verbAt v: Int) -> Verdict {
        let d = toks[v].depth
        var i = v + 1
        while i < toks.count {
            let t = toks[i]
            if t.depth < d { break }
            if t.depth == d, t.punct == 0x3B { break }
            if t.depth == d, t.word == "where" { return .write }
            i += 1
        }
        return .destructiveUnscoped
    }

    private static func previousWord(_ toks: [Tok], before i: Int) -> String? {
        guard i > 0 else { return nil }
        return toks[i - 1].word
    }

    private static func max(_ a: Verdict, _ b: Verdict) -> Verdict {
        a.severity >= b.severity ? a : b
    }

    private static func significantTokens(_ sql: String) -> [Tok] {
        let u = Array(sql.utf16)
        var out: [Tok] = []
        var depth = 0
        for t in SQLLexer.lex(utf16: u) {
            switch t.kind {
            case .whitespace, .lineComment, .blockComment:
                continue
            case .word:
                out.append(Tok(word: SQLLexer.lowerWord(t, in: u), punct: 0, depth: depth))
            case .punct:
                let c = u[t.range.location]
                if c == 0x29 { depth = Swift.max(0, depth - 1) }
                out.append(Tok(word: nil, punct: c, depth: depth))
                if c == 0x28 { depth += 1 }
            default:
                out.append(Tok(word: nil, punct: 0, depth: depth))
            }
        }
        return out
    }

    /// Identifiers/keywords of `sql` as written, skipping string literals,
    /// comments and dollar-quoted blocks; quoted identifiers contribute their
    /// unquoted body. Enough for keyword sniffing.
    static func tokens(in sql: String) -> [String] {
        let u = Array(sql.utf16)
        var out: [String] = []
        for t in SQLLexer.lex(utf16: u) {
            switch t.kind {
            case .word, .number: out.append(SQLLexer.text(t, in: u))
            case .quotedIdent: out.append(SQLLexer.quotedIdentBody(t, in: u))
            default: continue
            }
        }
        return out
    }
}
