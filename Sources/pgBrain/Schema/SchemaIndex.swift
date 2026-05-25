import Foundation

/// Prefix index over a `SchemaSnapshot` so the sidebar's filter field can
/// answer "tables starting with X" in O(prefix length + match count) even
/// on schemas with 50k+ relations. Built once per snapshot reload — the
/// cost is one walk of the tree.
///
/// Lookups are case-insensitive and match substrings (not just prefixes)
/// by indexing every byte offset. For a 10k-table schema that's ~200k
/// trie inserts — still <20ms on an M-series Mac, dwarfed by `NSOutlineView`
/// redisplay.
final class SchemaIndex {
    private final class Node {
        var children: [Character: Node] = [:]
        // Tables whose searchable string contains this prefix as a substring.
        // Use IDs (String) instead of TableNode to keep the trie small.
        var tableIDs: Set<String> = []
    }

    private let root = Node()
    private(set) var tablesByID: [String: TableNode] = [:]
    private(set) var totalTables: Int = 0

    init(snapshot: SchemaSnapshot) {
        for schema in snapshot.schemas {
            for table in schema.tables {
                tablesByID[table.id] = table
                totalTables += 1
                let needle = table.qualifiedName.lowercased()
                for start in 0..<needle.count {
                    var node = root
                    let from = needle.index(needle.startIndex, offsetBy: start)
                    for ch in needle[from...] {
                        node = node.children[ch] ?? {
                            let n = Node()
                            node.children[ch] = n
                            return n
                        }()
                        node.tableIDs.insert(table.id)
                    }
                }
            }
        }
    }

    /// Returns every TableNode whose qualified name contains `term`. Empty
    /// term returns nothing (filter-off behaviour belongs to the caller).
    func matches(_ term: String) -> [TableNode] {
        let needle = term.lowercased()
        guard !needle.isEmpty else { return [] }
        var node = root
        for ch in needle {
            guard let next = node.children[ch] else { return [] }
            node = next
        }
        return node.tableIDs.compactMap { tablesByID[$0] }
            .sorted { $0.qualifiedName < $1.qualifiedName }
    }
}
