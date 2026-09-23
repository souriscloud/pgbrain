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
    /// Schema for schema-qualified matching: with a qualifier set, a query
    /// like `pub.us` matches `pub` against it and `us` against the title.
    var qualifier: String? = nil
    /// Added to the match score (and used as the tiebreak for an empty
    /// query) so recents float up and hidden-schema objects sink.
    var rankBias: Int = 0
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
                    if a.rankBias != b.rankBias { return a.rankBias > b.rankBias }
                    return a.title.localizedCaseInsensitiveCompare(b.title) == .orderedAscending
                }
                .prefix(limit)
                .map { $0 }
        }

        var scored: [(item: CommandItem, score: Int)] = []
        scored.reserveCapacity(items.count)
        let qualified = q.contains(".") ? SchemaIndex.parse(q) : nil
        for item in items {
            if let qualified, let qualifier = item.qualifier {
                if let s = qualifiedScore(qualified, qualifier: qualifier, title: item.title) {
                    scored.append((item, s + item.rankBias))
                }
                continue
            }
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
            if let s = matched { scored.append((item, s + item.rankBias)) }
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

    private static func qualifiedScore(_ q: SchemaIndex.ParsedQuery, qualifier: String, title: String) -> Int? {
        var total = 0
        if let schemaNeedle = q.schema {
            guard let s = fuzzyScore(needle: schemaNeedle, haystack: SchemaIndex.lowered(qualifier)) else { return nil }
            total += s / 2
        }
        guard !q.name.isEmpty else { return total }
        guard let s = fuzzyScore(needle: q.name, haystack: SchemaIndex.lowered(title)) else { return nil }
        return total + s
    }

    /// Byte-level fuzzy scorer shared by the palette and the sidebar
    /// filter's `SchemaIndex`. Both inputs must already be lower-cased.
    /// Returns nil when `needle` isn't a subsequence of `haystack`.
    /// Contiguous substring hits dominate (prefix best), then word-boundary
    /// and run-length bonuses for scattered subsequence hits.
    static func fuzzyScore(needle n: [UInt8], haystack h: [UInt8]) -> Int? {
        guard !n.isEmpty else { return 0 }
        guard n.count <= h.count else { return nil }
        if let pos = substringIndex(of: n, in: h) {
            if pos == 0 { return 300 - min(h.count - n.count, 100) }
            let boundary = isBoundary(h[pos - 1])
            return (boundary ? 200 : 140) - min(pos, 40) - min(h.count - n.count, 40)
        }
        var s = 0
        var hi = 0
        var run = 0
        for c in n {
            var found = false
            while hi < h.count {
                let hc = h[hi]
                hi += 1
                if hc == c {
                    run += 1
                    s += 2 + min(run, 5)
                    if hi == 1 || isBoundary(h[hi - 2]) { s += 8 }
                    found = true
                    break
                }
                run = 0
            }
            if !found { return nil }
        }
        return s - h.count / 8
    }

    static func substringIndex(of needle: [UInt8], in hay: [UInt8]) -> Int? {
        guard !needle.isEmpty, needle.count <= hay.count else { return needle.isEmpty ? 0 : nil }
        let first = needle[0]
        var i = 0
        let last = hay.count - needle.count
        while i <= last {
            if hay[i] == first {
                var j = 1
                while j < needle.count, hay[i + j] == needle[j] { j += 1 }
                if j == needle.count { return i }
            }
            i += 1
        }
        return nil
    }

    private static func isBoundary(_ b: UInt8) -> Bool {
        b == UInt8(ascii: "_") || b == UInt8(ascii: " ") || b == UInt8(ascii: ".") || b == UInt8(ascii: "-")
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
        var q = needle.trimmingCharacters(in: .whitespaces).lowercased()
        if let dot = q.lastIndex(of: ".") { q = String(q[q.index(after: dot)...]) }
        guard !q.isEmpty else { return [] }
        let lower = title.lowercased()
        // Only safe when lower-casing kept the character count stable —
        // otherwise the indices below would not line up with `title`.
        guard lower.count == title.count else { return [] }
        if let r = lower.range(of: q) {
            let lo = title.index(title.startIndex, offsetBy: lower.distance(from: lower.startIndex, to: r.lowerBound))
            let hi = title.index(lo, offsetBy: q.count)
            return [lo..<hi]
        }
        var ranges: [Range<String.Index>] = []
        var titleIdx = title.startIndex
        var lowerIdx = lower.startIndex
        var qi = q.startIndex
        while qi < q.endIndex, lowerIdx < lower.endIndex {
            let nextTitle = title.index(after: titleIdx)
            if lower[lowerIdx] == q[qi] {
                ranges.append(titleIdx..<nextTitle)
                qi = q.index(after: qi)
            }
            titleIdx = nextTitle
            lowerIdx = lower.index(after: lowerIdx)
        }
        return qi == q.endIndex ? ranges : []
    }
}
