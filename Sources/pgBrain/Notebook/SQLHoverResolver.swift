import Foundation

/// Builds the short text shown on hover-to-identify over a SQL
/// identifier. Resolves the word against the live schema:
///   - schema name → "schema · N tables"
///   - table name  → "schema.table · N columns · PK"
///   - column name → list of every table that has a column with this
///     name, with the column's type + nullability
///   - anything else → nil (so AppKit suppresses the tooltip)
@MainActor
enum SQLHoverResolver {
    static func describe(identifier: String, in schema: SchemaSnapshot) -> String? {
        let needle = identifier.lowercased()

        // Schema match.
        if let sch = schema.schemas.first(where: { $0.name.lowercased() == needle }) {
            return "\(sch.name) · \(sch.tables.count) table\(sch.tables.count == 1 ? "" : "s")"
        }

        // Table match.
        for sch in schema.schemas {
            if let table = sch.tables.first(where: { $0.name.lowercased() == needle }) {
                var bits: [String] = []
                bits.append("\(sch.name).\(table.name)")
                bits.append("\(table.columns.count) column\(table.columns.count == 1 ? "" : "s")")
                if !table.primaryKey.isEmpty {
                    bits.append("PK: \(table.primaryKey.joined(separator: ", "))")
                }
                switch table.kind {
                case .view:             bits.append("view")
                case .materializedView: bits.append("materialized view")
                case .table:            break
                }
                return bits.joined(separator: " · ")
            }
        }

        // Column match — collate every (schema.table) that has a
        // column with this name. Cap at 5 hits so the tooltip stays
        // readable in tables where `id` exists in 50 places.
        var hits: [String] = []
        for sch in schema.schemas {
            for table in sch.tables {
                if let col = table.columns.first(where: { $0.name.lowercased() == needle }) {
                    let nullSuffix = col.nullable ? "" : " NOT NULL"
                    hits.append("\(sch.name).\(table.name).\(col.name)  \(col.typeName)\(nullSuffix)")
                }
            }
        }
        if !hits.isEmpty {
            return hits.prefix(5).joined(separator: "\n") + (hits.count > 5 ? "\n… +\(hits.count - 5) more" : "")
        }

        // Function match — collate every overload across schemas.
        var fns: [String] = []
        for sch in schema.schemas {
            for fn in sch.functions where fn.name.lowercased() == needle {
                let kindTag: String
                switch fn.kind {
                case .function:  kindTag = "fn"
                case .procedure: kindTag = "procedure"
                case .aggregate: kindTag = "aggregate"
                case .window:    kindTag = "window"
                }
                let ret = fn.returnType.isEmpty ? "" : " → \(fn.returnType)"
                fns.append("\(sch.name).\(fn.name)\(fn.arguments)\(ret)  [\(kindTag)]")
            }
        }
        if !fns.isEmpty {
            return fns.prefix(5).joined(separator: "\n") + (fns.count > 5 ? "\n… +\(fns.count - 5) more" : "")
        }

        return nil
    }
}
