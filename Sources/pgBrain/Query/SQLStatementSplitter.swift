import Foundation

/// Splits a SQL buffer into top-level statements separated by `;`. Aware of
/// single quotes, double-quoted identifiers, line comments (`--`), block
/// comments (`/* */`, nestable), and dollar-quoted strings (`$$…$$`,
/// `$tag$…$tag$`). The output is a list of statement ranges over the original
/// `String`'s UTF-8 view; trimmed-empty ranges are discarded.
enum SQLStatementSplitter {
    struct Statement {
        /// Range over the source buffer, on the `String`'s `Substring` view.
        let range: Range<String.Index>
        /// The trimmed statement text, ready to send to the server (no
        /// trailing semicolon, no surrounding whitespace).
        let trimmed: String
    }

    /// Splits `buffer` into statements. Empty or whitespace-only spans are
    /// dropped. A trailing statement without a closing `;` is included.
    static func split(_ buffer: String) -> [Statement] {
        var out: [Statement] = []
        var i = buffer.startIndex
        var statementStart = i
        let end = buffer.endIndex

        while i < end {
            let c = buffer[i]
            switch c {
            case "'":
                i = skipSingleQuoted(buffer, from: i)
            case "\"":
                i = skipDoubleQuoted(buffer, from: i)
            case "-":
                if let next = buffer.index(i, offsetBy: 1, limitedBy: end), next < end, buffer[next] == "-" {
                    i = skipLineComment(buffer, from: i)
                } else {
                    i = buffer.index(after: i)
                }
            case "/":
                if let next = buffer.index(i, offsetBy: 1, limitedBy: end), next < end, buffer[next] == "*" {
                    i = skipBlockComment(buffer, from: i)
                } else {
                    i = buffer.index(after: i)
                }
            case "$":
                if let (tagEnd, tag) = readDollarTag(buffer, from: i) {
                    i = skipDollarQuoted(buffer, from: tagEnd, tag: tag)
                } else {
                    i = buffer.index(after: i)
                }
            case ";":
                if let stmt = makeStatement(buffer, from: statementStart, to: i) {
                    out.append(stmt)
                }
                i = buffer.index(after: i)
                statementStart = i
            default:
                i = buffer.index(after: i)
            }
        }

        if let stmt = makeStatement(buffer, from: statementStart, to: end) {
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
        // Caret outside any range — pick the nearest preceding statement,
        // or the first one if the caret is before everything.
        return stmts.last(where: { $0.range.upperBound <= caret }) ?? stmts.first
    }

    // MARK: Skippers

    private static func skipSingleQuoted(_ s: String, from start: String.Index) -> String.Index {
        var i = s.index(after: start)
        while i < s.endIndex {
            if s[i] == "'" {
                let next = s.index(after: i)
                if next < s.endIndex, s[next] == "'" {
                    i = s.index(after: next)  // escaped ''
                    continue
                }
                return next
            }
            i = s.index(after: i)
        }
        return i
    }

    private static func skipDoubleQuoted(_ s: String, from start: String.Index) -> String.Index {
        var i = s.index(after: start)
        while i < s.endIndex {
            if s[i] == "\"" {
                let next = s.index(after: i)
                if next < s.endIndex, s[next] == "\"" {
                    i = s.index(after: next)
                    continue
                }
                return next
            }
            i = s.index(after: i)
        }
        return i
    }

    private static func skipLineComment(_ s: String, from start: String.Index) -> String.Index {
        var i = s.index(start, offsetBy: 2, limitedBy: s.endIndex) ?? s.endIndex
        while i < s.endIndex {
            if s[i] == "\n" { return s.index(after: i) }
            i = s.index(after: i)
        }
        return i
    }

    /// Block comments nest in PostgreSQL — `/* /* */ */` is one comment.
    private static func skipBlockComment(_ s: String, from start: String.Index) -> String.Index {
        var i = s.index(start, offsetBy: 2, limitedBy: s.endIndex) ?? s.endIndex
        var depth = 1
        while i < s.endIndex, depth > 0 {
            let next = s.index(after: i)
            if s[i] == "/", next < s.endIndex, s[next] == "*" {
                depth += 1
                i = s.index(after: next)
            } else if s[i] == "*", next < s.endIndex, s[next] == "/" {
                depth -= 1
                i = s.index(after: next)
            } else {
                i = s.index(after: i)
            }
        }
        return i
    }

    /// Reads a dollar-quote opening tag starting at `start` (which must point
    /// to `$`). Returns the index *after* the second `$` of the opening tag
    /// plus the tag itself (without surrounding `$`s), or `nil` if this isn't
    /// a valid dollar-quote opener.
    private static func readDollarTag(_ s: String, from start: String.Index) -> (String.Index, String)? {
        var i = s.index(after: start)
        var tag = ""
        while i < s.endIndex {
            let c = s[i]
            if c == "$" {
                return (s.index(after: i), tag)
            }
            // Tags are letters/digits/underscore; first char must not be a digit.
            // We don't enforce strictly — the closing $tag$ still has to match.
            if c.isLetter || c.isNumber || c == "_" {
                tag.append(c)
                i = s.index(after: i)
            } else {
                return nil
            }
        }
        return nil
    }

    private static func skipDollarQuoted(_ s: String, from start: String.Index, tag: String) -> String.Index {
        let closer = "$\(tag)$"
        var i = start
        while i < s.endIndex {
            if s[i] == "$", let match = s.range(of: closer, range: i..<s.endIndex)?.lowerBound, match == i {
                return s.index(i, offsetBy: closer.count, limitedBy: s.endIndex) ?? s.endIndex
            }
            i = s.index(after: i)
        }
        return i
    }

    private static func makeStatement(_ s: String, from lo: String.Index, to hi: String.Index) -> Statement? {
        let slice = s[lo..<hi]
        let trimmed = slice.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        return Statement(range: lo..<hi, trimmed: trimmed)
    }
}
