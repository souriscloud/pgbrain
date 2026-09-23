import Foundation

/// Splits a SQL buffer into top-level statements separated by `;`. Driven by
/// the shared `SQLLexer`, so semicolons inside strings (incl. `E'…\'…'`),
/// quoted identifiers, comments and dollar quotes never split, and
/// SQL-standard `BEGIN ATOMIC … END` function bodies stay in one piece.
/// Trimmed-empty statements are discarded.
enum SQLStatementSplitter {
    struct Statement {
        /// Range over the source buffer.
        let range: Range<String.Index>
        /// The trimmed statement text, ready to send to the server (no
        /// trailing semicolon, no surrounding whitespace).
        let trimmed: String
    }

    /// Splits `buffer` into statements. Empty or whitespace-only spans are
    /// dropped. A trailing statement without a closing `;` is included.
    static func split(_ buffer: String) -> [Statement] {
        let u = Array(buffer.utf16)
        let tokens = SQLLexer.lex(utf16: u)
        var out: [Statement] = []
        var statementStart = 0
        var atomicCaseDepth: Int? = nil   // non-nil while inside BEGIN ATOMIC … END

        var k = 0
        while k < tokens.count {
            let t = tokens[k]
            switch t.kind {
            case .word:
                let w = SQLLexer.lowerWord(t, in: u)
                if let depth = atomicCaseDepth {
                    if w == "case" {
                        atomicCaseDepth = depth + 1
                    } else if w == "end" {
                        atomicCaseDepth = depth > 0 ? depth - 1 : nil
                    }
                } else if w == "begin", let next = nextSignificant(tokens, after: k),
                          tokens[next].kind == .word, SQLLexer.lowerWord(tokens[next], in: u) == "atomic" {
                    // SQL-standard function bodies carry top-level semicolons
                    // that must NOT split the surrounding CREATE.
                    atomicCaseDepth = 0
                    k = next
                }
            case .punct where atomicCaseDepth == nil && u[t.range.location] == 0x3B:
                if let stmt = makeStatement(buffer, u, from: statementStart, to: t.range.location) {
                    out.append(stmt)
                }
                statementStart = t.upperBound
            default:
                break
            }
            k += 1
        }
        if let stmt = makeStatement(buffer, u, from: statementStart, to: u.count) {
            out.append(stmt)
        }
        return out
    }

    /// Returns the statement containing `caret`. If `caret` falls between
    /// statements (e.g. on whitespace just after a `;`), returns the
    /// statement immediately *before* the caret if any, otherwise the
    /// statement just after — matches what JetBrains tools do.
    static func statementAt(caret: String.Index, in buffer: String) -> Statement? {
        let stmts = split(buffer)
        guard !stmts.isEmpty else { return nil }
        for s in stmts where s.range.contains(caret) {
            return s
        }
        return stmts.last(where: { $0.range.upperBound <= caret }) ?? stmts.first
    }

    private static func nextSignificant(_ tokens: [SQLLexer.Token], after k: Int) -> Int? {
        var j = k + 1
        while j < tokens.count {
            if !SQLLexer.isTrivia(tokens[j].kind) { return j }
            j += 1
        }
        return nil
    }

    private static func makeStatement(_ s: String, _ u: [UInt16], from lo: Int, to hi: Int) -> Statement? {
        guard hi > lo else { return nil }
        let text = String(decoding: u[lo..<hi], as: UTF16.self)
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        let loIdx = String.Index(utf16Offset: lo, in: s)
        let hiIdx = String.Index(utf16Offset: hi, in: s)
        return Statement(range: loIdx..<hiIdx, trimmed: trimmed)
    }
}
