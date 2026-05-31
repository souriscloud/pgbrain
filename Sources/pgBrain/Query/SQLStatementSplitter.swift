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
            case "B", "b":
                // SQL-standard function bodies (`… LANGUAGE sql BEGIN ATOMIC
                // …; …; END`) carry top-level semicolons that must NOT split
                // the surrounding CREATE. Skip the whole atomic body as a unit.
                if isWordStart(buffer, at: i), let after = atomicBodyEnd(buffer, startingAtBegin: i) {
                    i = after
                } else {
                    i = buffer.index(after: i)
                }
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

    // MARK: BEGIN ATOMIC

    private static func isWordChar(_ c: Character) -> Bool { c.isLetter || c.isNumber || c == "_" }

    /// True when `i` sits at the start of a word (preceding char isn't a word
    /// char) — so we don't treat `…tablebegin` or `abEND` as keywords.
    private static func isWordStart(_ s: String, at i: String.Index) -> Bool {
        i == s.startIndex || !isWordChar(s[s.index(before: i)])
    }

    /// If the (case-insensitive) keyword `kw` matches a whole word starting at
    /// `i`, return the index just past it; otherwise `nil`. Caller guarantees
    /// `i` is at a word start.
    private static func matchWord(_ s: String, at i: String.Index, _ kw: String) -> String.Index? {
        var idx = i
        for ch in kw {
            guard idx < s.endIndex, Character(s[idx].lowercased()) == ch else { return nil }
            idx = s.index(after: idx)
        }
        if idx < s.endIndex, isWordChar(s[idx]) { return nil }   // not a whole word
        return idx
    }

    private static func skipSpaces(_ s: String, from i: String.Index) -> String.Index {
        var idx = i
        while idx < s.endIndex, s[idx].isWhitespace { idx = s.index(after: idx) }
        return idx
    }

    /// Given `start` at a `BEGIN` token, if it opens a `BEGIN ATOMIC` body,
    /// scan to the matching `END` (balancing `CASE … END`, and respecting
    /// quotes/comments/dollar-quotes inside) and return the index just past
    /// that `END`. Returns `nil` when this `BEGIN` isn't `BEGIN ATOMIC` (e.g. a
    /// bare `BEGIN;` transaction), so the caller advances normally.
    private static func atomicBodyEnd(_ s: String, startingAtBegin start: String.Index) -> String.Index? {
        guard let afterBegin = matchWord(s, at: start, "begin") else { return nil }
        let afterSpaces = skipSpaces(s, from: afterBegin)
        guard afterSpaces > afterBegin, let afterAtomic = matchWord(s, at: afterSpaces, "atomic") else { return nil }

        var i = afterAtomic
        var caseDepth = 0
        while i < s.endIndex {
            switch s[i] {
            case "'": i = skipSingleQuoted(s, from: i)
            case "\"": i = skipDoubleQuoted(s, from: i)
            case "-":
                if let n = s.index(i, offsetBy: 1, limitedBy: s.endIndex), n < s.endIndex, s[n] == "-" {
                    i = skipLineComment(s, from: i)
                } else { i = s.index(after: i) }
            case "/":
                if let n = s.index(i, offsetBy: 1, limitedBy: s.endIndex), n < s.endIndex, s[n] == "*" {
                    i = skipBlockComment(s, from: i)
                } else { i = s.index(after: i) }
            case "$":
                if let (tagEnd, tag) = readDollarTag(s, from: i) {
                    i = skipDollarQuoted(s, from: tagEnd, tag: tag)
                } else { i = s.index(after: i) }
            case "C", "c":
                if isWordStart(s, at: i), let after = matchWord(s, at: i, "case") {
                    caseDepth += 1; i = after
                } else { i = s.index(after: i) }
            case "E", "e":
                if isWordStart(s, at: i), let after = matchWord(s, at: i, "end") {
                    if caseDepth > 0 { caseDepth -= 1; i = after }
                    else { return after }   // closing END of the atomic body
                } else { i = s.index(after: i) }
            default:
                i = s.index(after: i)
            }
        }
        return i   // unterminated body — consume to end of buffer
    }

    private static func makeStatement(_ s: String, from lo: String.Index, to hi: String.Index) -> Statement? {
        let slice = s[lo..<hi]
        let trimmed = slice.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        return Statement(range: lo..<hi, trimmed: trimmed)
    }
}
