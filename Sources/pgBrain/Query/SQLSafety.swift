import Foundation

/// Static classification of a single SQL statement for the "you're about to
/// hose production" guardrail. Deliberately permissive — false positives are
/// cheap (a confirm dialog), false negatives expensive (an unscoped DELETE
/// hitting prod). We tokenize through the same quote/comment-aware lexer the
/// statement splitter already uses so `--` and `'... where ...'` don't fool
/// us.
enum SQLSafety {
    enum Verdict: Equatable {
        case readOnly
        case write                  // INSERT/UPDATE/DELETE/etc with a WHERE clause
        case destructiveUnscoped   // UPDATE/DELETE/TRUNCATE without WHERE
        case ddl                    // DROP/ALTER/TRUNCATE — always confirm on prod
    }

    static func classify(_ statement: String) -> Verdict {
        let tokens = tokens(in: statement)
        guard let first = tokens.first?.lowercased() else { return .readOnly }
        let uppercase = tokens.map { $0.lowercased() }

        switch first {
        case "select", "show", "explain", "with", "values", "table":
            // Even WITH could be a CTE that ends in DELETE — peek for it.
            if uppercase.contains(where: { ["delete", "update", "truncate", "drop", "alter"].contains($0) }) {
                return classifyMutation(tokens: uppercase)
            }
            return .readOnly
        case "insert":
            return .write
        case "update", "delete":
            return classifyMutation(tokens: uppercase)
        case "truncate":
            return .destructiveUnscoped
        case "drop", "alter", "grant", "revoke", "vacuum", "reindex", "create":
            return .ddl
        default:
            return .write
        }
    }

    private static func classifyMutation(tokens: [String]) -> Verdict {
        // If the statement contains a WHERE we treat it as scoped. Subqueries
        // (DELETE FROM t WHERE id IN (SELECT ...)) still count.
        tokens.contains("where") ? .write : .destructiveUnscoped
    }

    /// Tokenises identifiers/keywords out of `sql`, skipping string literals,
    /// line/block comments, and dollar-quoted blocks. Returns lowercase
    /// alphanumeric runs only — enough for keyword sniffing.
    static func tokens(in sql: String) -> [String] {
        var tokens: [String] = []
        var current = ""
        var i = sql.startIndex
        let end = sql.endIndex

        func flush() {
            if !current.isEmpty { tokens.append(current); current = "" }
        }

        while i < end {
            let c = sql[i]

            // Line comment
            if c == "-", sql.index(after: i) < end, sql[sql.index(after: i)] == "-" {
                flush()
                while i < end, sql[i] != "\n" { i = sql.index(after: i) }
                continue
            }

            // Block comment (non-nested for our purposes)
            if c == "/", sql.index(after: i) < end, sql[sql.index(after: i)] == "*" {
                flush()
                i = sql.index(i, offsetBy: 2)
                while i < end {
                    if sql[i] == "*", sql.index(after: i) < end, sql[sql.index(after: i)] == "/" {
                        i = sql.index(i, offsetBy: 2)
                        break
                    }
                    i = sql.index(after: i)
                }
                continue
            }

            // Single-quoted string with '' escape
            if c == "'" {
                flush()
                i = sql.index(after: i)
                while i < end {
                    if sql[i] == "'" {
                        if sql.index(after: i) < end, sql[sql.index(after: i)] == "'" {
                            i = sql.index(i, offsetBy: 2); continue
                        }
                        i = sql.index(after: i)
                        break
                    }
                    i = sql.index(after: i)
                }
                continue
            }

            // Dollar-quoted string: $tag$ ... $tag$
            if c == "$" {
                flush()
                let tagStart = sql.index(after: i)
                var tagEnd = tagStart
                while tagEnd < end, sql[tagEnd] != "$" { tagEnd = sql.index(after: tagEnd) }
                guard tagEnd < end else { break }
                let tag = String(sql[i...tagEnd]) // includes leading and trailing $
                i = sql.index(after: tagEnd)
                while i < end {
                    if sql[i] == "$", sql.distance(from: i, to: end) >= tag.count,
                       String(sql[i..<sql.index(i, offsetBy: tag.count)]) == tag {
                        i = sql.index(i, offsetBy: tag.count)
                        break
                    }
                    i = sql.index(after: i)
                }
                continue
            }

            // Double-quoted identifier — strip the quotes but keep the body
            // tokenised as one piece.
            if c == "\"" {
                flush()
                i = sql.index(after: i)
                while i < end, sql[i] != "\"" {
                    current.append(sql[i])
                    i = sql.index(after: i)
                }
                if i < end { i = sql.index(after: i) }
                flush()
                continue
            }

            if c.isLetter || c.isNumber || c == "_" {
                current.append(c)
            } else {
                flush()
            }
            i = sql.index(after: i)
        }
        flush()
        return tokens
    }
}
