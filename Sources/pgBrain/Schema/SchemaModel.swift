import Foundation

/// In-memory schema snapshot for one database. Built once per connect and
/// re-fetched on explicit refresh. Plain value types so SwiftUI/AppKit can
/// diff cheaply; identity for NSOutlineView is provided by `SidebarItem`.
struct SchemaSnapshot: Equatable, Sendable {
    var databaseName: String
    var schemas: [SchemaNode]

    static let empty = SchemaSnapshot(databaseName: "", schemas: [])
}

struct SchemaNode: Equatable, Identifiable, Sendable {
    var name: String
    var tables: [TableNode]
    var id: String { name }
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

    var id: String { "\(schema).\(name)" }
    var qualifiedName: String { "\(schema).\(name)" }
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
