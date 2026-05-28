import AppKit
import Foundation

/// One row in the command palette. Built fresh on each palette open so
/// it can capture live closures from the frontmost service; identity is
/// just for SwiftUI diffing.
@MainActor
struct CommandItem: Identifiable {
    enum Category: String, CaseIterable {
        case action     = "Action"
        case connection = "Connection"
        case table      = "Table"
        case function   = "Function"
        case schema     = "Schema"
        case tab        = "Tab"
        case query      = "Query"

        var sortOrder: Int {
            switch self {
            case .action:     0
            case .connection: 1
            case .tab:        2
            case .table:      3
            case .function:   4
            case .schema:     5
            case .query:      6
            }
        }
    }

    let id: String
    let icon: String           // SF Symbol name
    let title: String
    let subtitle: String?
    let category: Category
    let shortcut: String?      // visual hint only — e.g. "⌘N"
    let action: () -> Void
}

/// Scoring + filtering for the palette. Pure & main-actor-agnostic so
/// it stays cheap to re-run on every keystroke. The score blends a
/// classic fuzzy-subsequence match with prefix and word-boundary
/// bonuses so "us" surfaces "users" above "fundus" and "settings"
/// above "user_settings".
enum CommandMatcher {
    /// Returns the matched items sorted by descending score, capped at
    /// `limit`. An empty query returns everything in category order so
    /// the palette has useful default content the moment it opens.
    static func filter(_ items: [CommandItem], query: String, limit: Int = 200) -> [CommandItem] {
        let q = query.trimmingCharacters(in: .whitespaces)
        if q.isEmpty {
            return items
                .sorted { a, b in
                    if a.category.sortOrder != b.category.sortOrder {
                        return a.category.sortOrder < b.category.sortOrder
                    }
                    return a.title.localizedCaseInsensitiveCompare(b.title) == .orderedAscending
                }
                .prefix(limit)
                .map { $0 }
        }

        var scored: [(item: CommandItem, score: Int)] = []
        scored.reserveCapacity(items.count)
        for item in items {
            let hay = item.title + " " + (item.subtitle ?? "") + " " + item.category.rawValue
            // Strict subsequence first, then peel trailing chars off
            // the needle so over-typed queries like "connections" still
            // match items titled "New Connection…". We bail once we'd
            // be using less than 60% of the typed needle — below that
            // the user clearly meant something else.
            let minPrefix = max(1, Int((Double(q.count) * 0.6).rounded(.down)))
            var attempt = q
            var penalty = 0
            var matched: Int? = nil
            while attempt.count >= minPrefix {
                if let s = score(needle: attempt, haystack: hay, titleOnly: item.title) {
                    matched = s - penalty
                    break
                }
                attempt.removeLast()
                penalty += 8
            }
            if let s = matched { scored.append((item, s)) }
        }
        return scored
            .sorted { a, b in
                if a.score != b.score { return a.score > b.score }
                // Same score → category order, then alpha.
                if a.item.category.sortOrder != b.item.category.sortOrder {
                    return a.item.category.sortOrder < b.item.category.sortOrder
                }
                return a.item.title.localizedCaseInsensitiveCompare(b.item.title) == .orderedAscending
            }
            .prefix(limit)
            .map { $0.item }
    }

    /// Returns nil if `needle` is not a subsequence of `haystack`.
    /// Higher = better. Big bonuses: prefix match on title, contiguous
    /// runs, matches at word boundaries.
    private static func score(needle: String, haystack: String, titleOnly: String) -> Int? {
        let n = Array(needle.lowercased())
        let h = Array(haystack.lowercased())
        let t = titleOnly.lowercased()
        guard !n.isEmpty, !h.isEmpty else { return 0 }

        // Subsequence check first — bail early on misses.
        var hi = 0, ni = 0
        while ni < n.count, hi < h.count {
            if n[ni] == h[hi] { ni += 1 }
            hi += 1
        }
        guard ni == n.count else { return nil }

        var s = 0

        // Title-prefix dominates everything.
        if t.hasPrefix(needle.lowercased()) {
            s += 200 - (titleOnly.count - needle.count)
        } else if t.contains(needle.lowercased()) {
            s += 80
        }

        // Reward contiguous runs and word-boundary hits during the
        // second walk so "ut" prefers "user_table" over "buttress".
        var ni2 = 0
        var hi2 = 0
        var runLen = 0
        var prev: Character = " "
        while ni2 < n.count, hi2 < h.count {
            let c = h[hi2]
            if n[ni2] == c {
                runLen += 1
                s += 1
                if hi2 == 0 || prev == " " || prev == "_" || prev == "." || prev == "-" {
                    s += 6        // word boundary bonus
                }
                s += min(runLen, 5)  // contiguity bonus capped
                ni2 += 1
            } else {
                runLen = 0
            }
            prev = c
            hi2 += 1
        }

        // Penalise long haystacks slightly so equally-scored short
        // strings sort first.
        s -= h.count / 32
        return s
    }

    /// Returns (lowerBound, upperBound) index ranges in `title` where
    /// the needle's characters matched, suitable for highlight rendering.
    static func matchedRanges(in title: String, needle: String) -> [Range<String.Index>] {
        let q = needle.trimmingCharacters(in: .whitespaces).lowercased()
        guard !q.isEmpty else { return [] }
        let lower = title.lowercased()
        var ranges: [Range<String.Index>] = []
        var titleIdx = lower.startIndex
        var qi = q.startIndex
        while qi < q.endIndex, titleIdx < lower.endIndex {
            if lower[titleIdx] == q[qi] {
                let next = lower.index(after: titleIdx)
                ranges.append(titleIdx..<next)
                qi = q.index(after: qi)
            }
            titleIdx = lower.index(after: titleIdx)
        }
        return qi == q.endIndex ? ranges : []
    }
}
