import Foundation

/// In-memory schema snapshot for one database. Built once per connect and
/// re-fetched on explicit refresh. Plain value types so SwiftUI/AppKit can
/// diff cheaply; identity for NSOutlineView is provided by `SidebarItem`.
struct SchemaSnapshot: Equatable, Sendable {
    var databaseName: String
    var schemas: [SchemaNode]

    static let empty = SchemaSnapshot(databaseName: "", schemas: [])

    /// `"schema\u{1F}table"` → `[ColumnNode]`. Used by the lazy-load
    /// path: `SchemaFetcher.fetchColumnsAll` produces one of these,
    /// `merging(columns:)` folds it back into the snapshot in place.
    typealias ColumnMap = [String: [ColumnNode]]

    /// Returns a copy of the snapshot with each table's column list
    /// populated from `columns`. Tables missing from the map are
    /// left untouched so per-table on-demand loads layered on top
    /// don't get clobbered.
    func merging(columns: ColumnMap) -> SchemaSnapshot {
        var out = self
        for i in out.schemas.indices {
            for j in out.schemas[i].tables.indices {
                let key = "\(out.schemas[i].name)\u{1F}\(out.schemas[i].tables[j].name)"
                if let cols = columns[key] {
                    out.schemas[i].tables[j].columns = cols
                }
            }
        }
        return out
    }

    /// Set the column list for one specific table (used by the
    /// single-table on-demand loader). No-op when the table isn't
    /// in the snapshot.
    func mergingColumns(forSchema schema: String, table: String, columns: [ColumnNode]) -> SchemaSnapshot {
        var out = self
        guard let i = out.schemas.firstIndex(where: { $0.name == schema }),
              let j = out.schemas[i].tables.firstIndex(where: { $0.name == table })
        else { return out }
        out.schemas[i].tables[j].columns = columns
        return out
    }
}

struct SchemaNode: Equatable, Identifiable, Sendable {
    var name: String
    var tables: [TableNode]
    /// User-defined functions/procedures living in this schema. Filled
    /// from `pg_proc` on schema load (skipping anything in
    /// `pg_catalog` / `information_schema`).
    var functions: [FunctionNode] = []
    var id: String { name }
}

/// A user-defined function or procedure. Just enough metadata to drive
/// completion suggestions + hover tooltips; we deliberately don't try
/// to surface the body or overload-resolve at edit time.
struct FunctionNode: Equatable, Identifiable, Sendable {
    enum Kind: String, Equatable, Sendable {
        case function     // `f` — returns a value
        case procedure    // `p` — CALL-able, side-effecting
        case aggregate    // `a`
        case window       // `w`
    }
    var schema: String
    var name: String
    var kind: Kind
    /// Pretty-printed argument list (`(text, integer DEFAULT 0)`).
    var arguments: String
    /// Pretty-printed return type (`integer`, `SETOF text`). Empty for
    /// procedures.
    var returnType: String
    var id: String { "\(schema).\(name)(\(arguments))" }

    var signature: String { "\(name)\(arguments)" }
    var qualifiedSignature: String { "\(schema).\(signature)" }
}

struct TableNode: Equatable, Identifiable, Sendable {
    enum Kind: String, Equatable, Sendable {
        case table          // pg_class.relkind = 'r' (also 'p' partitioned)
        case view           // 'v'
        case materializedView // 'm'
    }
    var schema: String
    var name: String
    var kind: Kind
    var columns: [ColumnNode]
    /// Names of columns making up the primary key, in index order. Empty when
    /// the relation has no primary key (or is a view) — gates row editing.
    var primaryKey: [String] = []
    /// Single-column foreign keys discovered on this table. Powers
    /// ⌘-click "jump to parent row" in the data grid. Composite FKs
    /// are skipped for v1 — they'd need every key column's cell value
    /// gathered to navigate cleanly.
    var foreignKeys: [ForeignKey] = []

    var id: String { "\(schema).\(name)" }
    var qualifiedName: String { "\(schema).\(name)" }

    /// Editing is only meaningful on real tables that have a PK we can target
    /// in a UPDATE's WHERE clause.
    var isEditable: Bool {
        (kind == .table) && !primaryKey.isEmpty
    }

    /// Looks up the `ColumnNode`s named by `primaryKey`, preserving PK order.
    /// Missing names (shouldn't happen if schema is consistent) are dropped.
    var primaryKeyColumns: [ColumnNode] {
        primaryKey.compactMap { name in columns.first(where: { $0.name == name }) }
    }
}

struct ForeignKey: Equatable, Sendable {
    var localColumn: String
    var refSchema: String
    var refTable: String
    var refColumn: String
}

struct ColumnNode: Equatable, Identifiable, Sendable {
    var name: String
    /// Result of `format_type(atttypid, atttypmod)` — e.g. "integer", "text",
    /// "character varying(255)", "timestamp with time zone".
    var typeName: String
    var nullable: Bool
    var ordinal: Int

    var id: Int { ordinal }
}

/// High-level type bucket used to pick a cell renderer / editor.
enum ColumnTypeKind: Sendable {
    case text, integer, number, bool, timestamp, date, json, uuid, bytes, unknown

    static func from(typeName: String) -> ColumnTypeKind {
        let t = typeName.lowercased()
        if t.hasPrefix("character") || t == "text" || t == "name" || t == "varchar" || t.hasPrefix("varchar") { return .text }
        if t == "smallint" || t == "integer" || t == "bigint" || t == "int2" || t == "int4" || t == "int8" || t == "oid" { return .integer }
        if t == "real" || t == "double precision" || t.hasPrefix("numeric") || t == "money" { return .number }
        if t == "boolean" { return .bool }
        if t.hasPrefix("timestamp") { return .timestamp }
        if t == "date" || t == "time" || t.hasPrefix("time ") { return .date }
        if t == "json" || t == "jsonb" { return .json }
        if t == "uuid" { return .uuid }
        if t == "bytea" { return .bytes }
        return .unknown
    }
}
