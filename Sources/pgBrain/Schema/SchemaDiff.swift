import Foundation

/// Produces a structural diff between two `SchemaSnapshot`s. Reports
/// table-level adds/removes and per-table column adds/removes/type-changes.
/// Doesn't compare indexes, triggers, or foreign keys yet — those need
/// catalog queries the `SchemaFetcher` doesn't fan out to today.
enum SchemaDiff {
    struct Result: Sendable {
        var addedTables: [TableNode]            // present in right, absent in left
        var removedTables: [TableNode]          // present in left, absent in right
        var changedTables: [TableChange]
        var isEmpty: Bool {
            addedTables.isEmpty && removedTables.isEmpty && changedTables.isEmpty
        }
    }

    struct TableChange: Sendable, Identifiable {
        let left: TableNode
        let right: TableNode
        var addedColumns: [ColumnNode]          // present in right
        var removedColumns: [ColumnNode]        // present in left
        var changedColumns: [ColumnChange]
        var id: String { left.id }

        var hasChanges: Bool {
            !addedColumns.isEmpty || !removedColumns.isEmpty || !changedColumns.isEmpty
        }
    }

    struct ColumnChange: Sendable, Identifiable {
        let name: String
        let leftType: String
        let rightType: String
        let leftNullable: Bool
        let rightNullable: Bool

        var id: String { name }
    }

    static func diff(left: SchemaSnapshot, right: SchemaSnapshot) -> Result {
        let leftIndex = index(left)
        let rightIndex = index(right)

        var added: [TableNode] = []
        var removed: [TableNode] = []
        var changed: [TableChange] = []

        for (key, table) in rightIndex where leftIndex[key] == nil {
            added.append(table)
        }
        for (key, table) in leftIndex where rightIndex[key] == nil {
            removed.append(table)
        }
        for (key, lTable) in leftIndex {
            guard let rTable = rightIndex[key] else { continue }
            let change = diffTables(left: lTable, right: rTable)
            if change.hasChanges { changed.append(change) }
        }
        added.sort { $0.qualifiedName < $1.qualifiedName }
        removed.sort { $0.qualifiedName < $1.qualifiedName }
        changed.sort { $0.left.qualifiedName < $1.left.qualifiedName }
        return Result(addedTables: added, removedTables: removed, changedTables: changed)
    }

    private static func index(_ snapshot: SchemaSnapshot) -> [String: TableNode] {
        var out: [String: TableNode] = [:]
        for schema in snapshot.schemas {
            for table in schema.tables {
                out[table.id] = table
            }
        }
        return out
    }

    private static func diffTables(left: TableNode, right: TableNode) -> TableChange {
        let leftCols = Dictionary(uniqueKeysWithValues: left.columns.map { ($0.name, $0) })
        let rightCols = Dictionary(uniqueKeysWithValues: right.columns.map { ($0.name, $0) })

        var added: [ColumnNode] = []
        var removed: [ColumnNode] = []
        var changed: [ColumnChange] = []

        for (name, col) in rightCols where leftCols[name] == nil {
            added.append(col)
        }
        for (name, col) in leftCols where rightCols[name] == nil {
            removed.append(col)
        }
        for (name, l) in leftCols {
            guard let r = rightCols[name] else { continue }
            if l.typeName != r.typeName || l.nullable != r.nullable {
                changed.append(ColumnChange(
                    name: name,
                    leftType: l.typeName, rightType: r.typeName,
                    leftNullable: l.nullable, rightNullable: r.nullable
                ))
            }
        }
        added.sort { $0.name < $1.name }
        removed.sort { $0.name < $1.name }
        changed.sort { $0.name < $1.name }
        return TableChange(
            left: left, right: right,
            addedColumns: added, removedColumns: removed, changedColumns: changed
        )
    }
}
