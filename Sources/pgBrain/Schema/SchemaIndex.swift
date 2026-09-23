import Foundation

/// Search index over a `SchemaSnapshot`, built once per snapshot reload and
/// queried on every filter keystroke.
///
/// Each searchable object is flattened into an `Entry` carrying its
/// lower-cased UTF-8 bytes plus a 64-bit "which characters occur" mask.
/// A query first rejects entries whose mask doesn't cover the query's mask
/// (one AND per entry), and only survivors pay for the subsequence scorer.
/// Typing forward also narrows from the previous result set instead of the
/// whole index, so the per-keystroke cost falls as the query grows.
final class SchemaIndex {
    enum EntryKind: Equatable {
        case relation
        case function
        case column
    }

    struct Entry {
        let kind: EntryKind
        let schema: String
        let name: String
        /// Owning relation's id for relations and columns; nil for functions.
        let tableID: String?
        /// Function id for functions.
        let functionID: String?
        let isExtensionOwned: Bool
        fileprivate let schemaBytes: [UInt8]
        fileprivate let nameBytes: [UInt8]
        fileprivate let mask: UInt64
        fileprivate let schemaMask: UInt64
    }

    struct Hit {
        let entry: Entry
        let score: Int
    }

    private(set) var tablesByID: [String: TableNode] = [:]
    private(set) var functionsByID: [String: FunctionNode] = [:]
    private(set) var totalTables: Int = 0
    private(set) var entries: [Entry] = []
    /// Column entries live apart so the default (columns off) path never
    /// touches them.
    private var columnEntries: [Entry] = []

    private var lastQuery: (key: String, includeColumns: Bool, hits: [Int], columnHits: [Int])?

    init(snapshot: SchemaSnapshot) {
        for schema in snapshot.schemas {
            let schemaBytes = Self.lowered(schema.name)
            let schemaMask = Self.mask(of: schemaBytes)
            for table in schema.tables {
                tablesByID[table.id] = table
                totalTables += 1
                let nameBytes = Self.lowered(table.name)
                entries.append(Entry(
                    kind: .relation, schema: schema.name, name: table.name,
                    tableID: table.id, functionID: nil,
                    isExtensionOwned: table.isExtensionOwned,
                    schemaBytes: schemaBytes, nameBytes: nameBytes,
                    mask: Self.mask(of: nameBytes), schemaMask: schemaMask
                ))
                for col in table.columns {
                    let colBytes = Self.lowered(col.name)
                    columnEntries.append(Entry(
                        kind: .column, schema: schema.name, name: col.name,
                        tableID: table.id, functionID: nil,
                        isExtensionOwned: table.isExtensionOwned,
                        schemaBytes: schemaBytes, nameBytes: colBytes,
                        mask: Self.mask(of: colBytes), schemaMask: schemaMask
                    ))
                }
            }
            for fn in schema.functions {
                functionsByID[fn.id] = fn
                let nameBytes = Self.lowered(fn.name)
                entries.append(Entry(
                    kind: .function, schema: schema.name, name: fn.name,
                    tableID: nil, functionID: fn.id,
                    isExtensionOwned: fn.isExtensionOwned,
                    schemaBytes: schemaBytes, nameBytes: nameBytes,
                    mask: Self.mask(of: nameBytes), schemaMask: schemaMask
                ))
            }
        }
    }

    /// Substring match on `schema.name`, relations only, sorted by
    /// qualified name. Empty term returns nothing.
    func matches(_ term: String) -> [TableNode] {
        let needle = Self.lowered(term)
        guard !needle.isEmpty else { return [] }
        let qMask = Self.mask(of: needle)
        var out: [TableNode] = []
        for e in entries where e.kind == .relation {
            guard (e.mask | e.schemaMask | Self.dotBit) & qMask == qMask else { continue }
            let hay = e.schemaBytes + [UInt8(ascii: ".")] + e.nameBytes
            if CommandMatcher.substringIndex(of: needle, in: hay) != nil,
               let id = e.tableID, let t = tablesByID[id] {
                out.append(t)
            }
        }
        return out.sorted { $0.qualifiedName < $1.qualifiedName }
    }

    /// Fuzzy subsequence search over relations + functions (and columns
    /// when `includeColumns`). A query containing `.` is split into a
    /// schema part and a name part, each matched against its own field, so
    /// `pub.us` finds `public.users`. Results are sorted best-first.
    func fuzzy(_ query: String, includeColumns: Bool = false, limit: Int = 5000) -> [Hit] {
        let trimmed = query.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return [] }
        let parsed = Self.parse(trimmed)

        // Forward typing (the new query extends the old one) can only
        // shrink the match set, so rescan just the previous survivors.
        let key = trimmed.lowercased()
        let reuse: (hits: [Int], columnHits: [Int])? = {
            guard let last = lastQuery, last.includeColumns == includeColumns,
                  key.hasPrefix(last.key), !last.key.isEmpty,
                  key.contains(".") == last.key.contains(".") else { return nil }
            return (last.hits, last.columnHits)
        }()

        var hits: [(Int, Int)] = []
        let candidates = reuse?.hits ?? Array(entries.indices)
        for i in candidates {
            if let s = Self.score(entries[i], parsed) { hits.append((i, s)) }
        }
        var columnHits: [(Int, Int)] = []
        if includeColumns {
            let colCandidates = reuse?.columnHits ?? Array(columnEntries.indices)
            for i in colCandidates {
                if let s = Self.score(columnEntries[i], parsed) { columnHits.append((i, s - 20)) }
            }
        }
        lastQuery = (key, includeColumns, hits.map(\.0), columnHits.map(\.0))

        var out: [Hit] = hits.map { Hit(entry: entries[$0.0], score: $0.1) }
        out += columnHits.map { Hit(entry: columnEntries[$0.0], score: $0.1) }
        out.sort { a, b in
            if a.score != b.score { return a.score > b.score }
            if a.entry.name.count != b.entry.name.count { return a.entry.name.count < b.entry.name.count }
            return a.entry.name < b.entry.name
        }
        if out.count > limit { out.removeSubrange(limit...) }
        return out
    }

    // MARK: - Internals

    struct ParsedQuery {
        let schema: [UInt8]?
        let name: [UInt8]
        let schemaMask: UInt64
        let nameMask: UInt64
    }

    static func parse(_ query: String) -> ParsedQuery {
        let lowered = Self.lowered(query)
        if let dot = lowered.firstIndex(of: UInt8(ascii: ".")) {
            let schema = Array(lowered[..<dot])
            let name = Array(lowered[(dot + 1)...])
            return ParsedQuery(schema: schema.isEmpty ? nil : schema, name: name,
                               schemaMask: mask(of: schema), nameMask: mask(of: name))
        }
        return ParsedQuery(schema: nil, name: lowered, schemaMask: 0, nameMask: mask(of: lowered))
    }

    private static func score(_ e: Entry, _ q: ParsedQuery) -> Int? {
        guard e.mask & q.nameMask == q.nameMask,
              e.schemaMask & q.schemaMask == q.schemaMask else { return nil }
        var total = 0
        if let schemaNeedle = q.schema {
            guard let s = CommandMatcher.fuzzyScore(needle: schemaNeedle, haystack: e.schemaBytes) else { return nil }
            total += s / 2
        }
        if q.name.isEmpty { return total }
        guard let s = CommandMatcher.fuzzyScore(needle: q.name, haystack: e.nameBytes) else { return nil }
        return total + s
    }

    private static let dotBit: UInt64 = mask(of: [UInt8(ascii: ".")])

    static func lowered(_ s: String) -> [UInt8] {
        s.utf8.map { ($0 >= 65 && $0 <= 90) ? $0 + 32 : $0 }
    }

    static func mask(of bytes: [UInt8]) -> UInt64 {
        var m: UInt64 = 0
        for b in bytes { m |= 1 << UInt64(b & 63) }
        return m
    }
}
