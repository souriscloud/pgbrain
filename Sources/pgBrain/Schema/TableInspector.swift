import Foundation
import PostgresNIO

/// Fetches the metadata needed to render either a structural overview of
/// a table (column list with types/nullability/defaults, constraints,
/// indexes, comments) or a recreation-ready `CREATE TABLE` script. The
/// composer leans on Postgres' own `pg_get_constraintdef` /
/// `pg_get_indexdef` / `format_type` server-side functions so we don't
/// reinvent SQL syntax — and so partial / exclusion / expression
/// constraints just come back rendered correctly.
@MainActor
enum TableInspector {
    struct Column: Sendable {
        let name: String
        let typeName: String      // `format_type` output, e.g. "character varying(255)"
        let nullable: Bool
        let defaultExpr: String?  // raw SQL of the DEFAULT clause, nil if none
        let identity: String?     // "a" = always, "d" = by default, nil otherwise
        let generated: String?    // "s" = stored, nil otherwise
        let comment: String?
        let ordinal: Int
    }

    struct Constraint: Sendable {
        /// One of: 'p' primary key, 'u' unique, 'f' foreign key, 'c' check,
        /// 'x' exclusion. Used to bucket the rows visually in the Structure
        /// pane; the `def` already contains the full SQL fragment so we
        /// don't need to inspect this beyond grouping.
        let kind: Character
        let name: String
        let definition: String    // result of pg_get_constraintdef(oid)
    }

    struct Index: Sendable {
        let name: String
        let definition: String    // result of pg_get_indexdef(oid)
    }

    struct Trigger: Sendable {
        let name: String
        let enabled: Bool         // tgenabled: 'O' or 'A' = on, 'D' = off, 'R' = replica
        let definition: String    // result of pg_get_triggerdef(oid)
    }

    struct Snapshot: Sendable {
        let schema: String
        let table: String
        let kind: TableNode.Kind
        let comment: String?
        let columns: [Column]
        let constraints: [Constraint]
        /// Indexes that are NOT already represented by a constraint
        /// (PK / UK indexes are skipped — they'd duplicate the constraint
        /// definitions in the rendered DDL).
        let indexes: [Index]
        let triggers: [Trigger]
    }

    static func fetch(
        client: PostgresClient,
        schema: String,
        table: String
    ) async throws -> Snapshot {
        // Resolve the relation's oid up front so the four subsequent
        // queries can all use the same target. Avoids re-resolving
        // pg_class.oid four times and avoids any edge case where a
        // search_path change between queries could move the target.
        let oid = try await fetchOID(client: client, schema: schema, table: table)
        let kind = try await fetchKind(client: client, oid: oid)
        async let cols = fetchColumns(client: client, oid: oid)
        async let cons = fetchConstraints(client: client, oid: oid)
        async let idxs = fetchIndexes(client: client, oid: oid)
        async let trigs = fetchTriggers(client: client, oid: oid)
        async let tableComment = fetchTableComment(client: client, oid: oid)
        return Snapshot(
            schema: schema,
            table: table,
            kind: kind,
            comment: try await tableComment,
            columns: try await cols,
            constraints: try await cons,
            indexes: try await idxs,
            triggers: try await trigs
        )
    }

    /// Assembles the snapshot into a `CREATE TABLE` script (plus indexes
    /// and COMMENTs) suitable for copy-paste recreation. Views and
    /// materialised views get a `CREATE VIEW ... AS` / `CREATE MATERIALIZED
    /// VIEW ... AS` fetched from `pg_get_viewdef`.
    static func renderDDL(
        client: PostgresClient,
        snapshot: Snapshot
    ) async throws -> String {
        if snapshot.kind == .view || snapshot.kind == .materializedView {
            return try await renderViewDDL(client: client, snapshot: snapshot)
        }
        return renderTableDDL(snapshot)
    }

    // MARK: - DDL rendering

    private static func renderTableDDL(_ s: Snapshot) -> String {
        var out = ""
        let qualified = SQLIdent.quote(s.schema) + "." + SQLIdent.quote(s.table)
        out += "-- Table DDL — \(s.schema).\(s.table)\n\n"

        out += "CREATE TABLE \(qualified) (\n"
        // Column definitions, then inline constraints (PK / UK / CHECK
        // get inlined; FKs stay inline too because pg_get_constraintdef
        // produces a complete REFERENCES clause).
        var lines: [String] = s.columns.map { renderColumnLine($0) }
        for c in s.constraints {
            lines.append("    CONSTRAINT \(SQLIdent.quote(c.name)) \(c.definition)")
        }
        out += lines.joined(separator: ",\n")
        out += "\n);\n"

        // Indexes that aren't already constraint-backed.
        if !s.indexes.isEmpty {
            out += "\n"
            for idx in s.indexes {
                out += idx.definition + ";\n"
            }
        }

        // Comments.
        if let comment = s.comment {
            out += "\nCOMMENT ON TABLE \(qualified) IS \(quotedLiteral(comment));\n"
        }
        var anyColComments = false
        for col in s.columns where col.comment != nil {
            if !anyColComments {
                out += "\n"
                anyColComments = true
            }
            let colQualified = qualified + "." + SQLIdent.quote(col.name)
            out += "COMMENT ON COLUMN \(colQualified) IS \(quotedLiteral(col.comment!));\n"
        }
        return out
    }

    private static func renderColumnLine(_ c: Column) -> String {
        var line = "    " + SQLIdent.quote(c.name) + " " + c.typeName
        if let g = c.generated, g == "s", let def = c.defaultExpr {
            // Stored generated columns: GENERATED ALWAYS AS (...) STORED
            line += " GENERATED ALWAYS AS (\(def)) STORED"
        } else if let id = c.identity, id == "a" || id == "d" {
            line += id == "a" ? " GENERATED ALWAYS AS IDENTITY" : " GENERATED BY DEFAULT AS IDENTITY"
        } else if let def = c.defaultExpr {
            line += " DEFAULT \(def)"
        }
        if !c.nullable { line += " NOT NULL" }
        return line
    }

    private static func renderViewDDL(client: PostgresClient, snapshot s: Snapshot) async throws -> String {
        let qualified = SQLIdent.quote(s.schema) + "." + SQLIdent.quote(s.table)
        let kindWord = s.kind == .materializedView ? "MATERIALIZED VIEW" : "VIEW"
        let body: String = try await {
            let rows = try await client.query(
                "SELECT pg_get_viewdef(\(SQLIdent.quote(s.schema) + "." + SQLIdent.quote(s.table)), true)"
            )
            var def = ""
            for try await row in rows.decode(String.self) {
                def = row
            }
            return def
        }()
        var out = "-- \(kindWord.capitalized) DDL — \(s.schema).\(s.table)\n\n"
        out += "CREATE OR REPLACE \(kindWord) \(qualified) AS\n\(body)\n"
        if let comment = s.comment {
            out += "\nCOMMENT ON \(kindWord) \(qualified) IS \(quotedLiteral(comment));\n"
        }
        return out
    }

    private static func quotedLiteral(_ s: String) -> String {
        "'" + s.replacingOccurrences(of: "'", with: "''") + "'"
    }

    // MARK: - Catalog queries

    private static func fetchOID(client: PostgresClient, schema: String, table: String) async throws -> Int64 {
        let sql: PostgresQuery = """
        SELECT c.oid::int8
        FROM pg_class c
        JOIN pg_namespace n ON n.oid = c.relnamespace
        WHERE n.nspname = \(schema) AND c.relname = \(table)
        LIMIT 1
        """
        let rows = try await client.query(sql)
        for try await oid in rows.decode(Int64.self) {
            return oid
        }
        throw InspectorError.notFound(schema: schema, table: table)
    }

    private static func fetchKind(client: PostgresClient, oid: Int64) async throws -> TableNode.Kind {
        let sql: PostgresQuery = """
        SELECT relkind::text FROM pg_class WHERE oid = \(oid)::oid
        """
        let rows = try await client.query(sql)
        for try await k in rows.decode(String.self) {
            switch k {
            case "v": return .view
            case "m": return .materializedView
            default:  return .table
            }
        }
        return .table
    }

    private static func fetchColumns(client: PostgresClient, oid: Int64) async throws -> [Column] {
        // pg_attrdef stores the raw expression for each DEFAULT (one row
        // per defaulted column); we LEFT JOIN so columns without a
        // default still come back. `col_description` is the documented
        // way to grab a column's COMMENT.
        let sql: PostgresQuery = """
        SELECT a.attname,
               format_type(a.atttypid, a.atttypmod),
               (NOT a.attnotnull),
               pg_get_expr(d.adbin, d.adrelid),
               nullif(a.attidentity::text, ''),
               nullif(a.attgenerated::text, ''),
               col_description(a.attrelid, a.attnum),
               a.attnum::int
        FROM pg_attribute a
        LEFT JOIN pg_attrdef d ON d.adrelid = a.attrelid AND d.adnum = a.attnum
        WHERE a.attrelid = \(oid)::oid
          AND a.attnum > 0
          AND NOT a.attisdropped
        ORDER BY a.attnum
        """
        let rows = try await client.query(sql)
        var out: [Column] = []
        for try await (name, typeName, nullable, def, identity, generated, comment, ord)
            in rows.decode((String, String, Bool, String?, String?, String?, String?, Int).self) {
            out.append(Column(
                name: name,
                typeName: typeName,
                nullable: nullable,
                defaultExpr: def,
                identity: identity,
                generated: generated,
                comment: comment,
                ordinal: ord
            ))
        }
        return out
    }

    private static func fetchConstraints(client: PostgresClient, oid: Int64) async throws -> [Constraint] {
        // Constraint kinds: 'p' primary, 'u' unique, 'f' foreign,
        // 'c' check, 'x' exclude. ORDER places PK first, then UK, then
        // FK, then CHECK so the rendered DDL reads naturally.
        let sql: PostgresQuery = """
        SELECT contype::text, conname, pg_get_constraintdef(oid)
        FROM pg_constraint
        WHERE conrelid = \(oid)::oid
        ORDER BY
            CASE contype WHEN 'p' THEN 0 WHEN 'u' THEN 1 WHEN 'f' THEN 2 WHEN 'c' THEN 3 ELSE 4 END,
            conname
        """
        let rows = try await client.query(sql)
        var out: [Constraint] = []
        for try await (kind, name, def) in rows.decode((String, String, String).self) {
            out.append(Constraint(kind: kind.first ?? "c", name: name, definition: def))
        }
        return out
    }

    private static func fetchIndexes(client: PostgresClient, oid: Int64) async throws -> [Index] {
        // Skip the index that's already backing a PK or UK constraint;
        // those are emitted as part of the constraint clauses, so
        // re-listing the underlying index would produce duplicate-
        // looking DDL on copy-paste.
        let sql: PostgresQuery = """
        SELECT i.relname, pg_get_indexdef(i.oid)
        FROM pg_index x
        JOIN pg_class i ON i.oid = x.indexrelid
        WHERE x.indrelid = \(oid)::oid
          AND NOT EXISTS (
              SELECT 1 FROM pg_constraint c
              WHERE c.conindid = x.indexrelid
          )
        ORDER BY i.relname
        """
        let rows = try await client.query(sql)
        var out: [Index] = []
        for try await (name, def) in rows.decode((String, String).self) {
            out.append(Index(name: name, definition: def))
        }
        return out
    }

    private static func fetchTriggers(client: PostgresClient, oid: Int64) async throws -> [Trigger] {
        // Skip the internally-generated triggers (constraint-backed FKs
        // create a hidden trigger pair we don't want to surface).
        let sql: PostgresQuery = """
        SELECT t.tgname,
               (t.tgenabled::text IN ('O','A','R')),
               pg_get_triggerdef(t.oid, true)
        FROM pg_trigger t
        WHERE t.tgrelid = \(oid)::oid
          AND NOT t.tgisinternal
        ORDER BY t.tgname
        """
        let rows = try await client.query(sql)
        var out: [Trigger] = []
        for try await (name, enabled, def) in rows.decode((String, Bool, String).self) {
            out.append(Trigger(name: name, enabled: enabled, definition: def))
        }
        return out
    }

    private static func fetchTableComment(client: PostgresClient, oid: Int64) async throws -> String? {
        let sql: PostgresQuery = "SELECT obj_description(\(oid)::oid, 'pg_class')"
        let rows = try await client.query(sql)
        for try await c in rows.decode(String?.self) {
            return c
        }
        return nil
    }

    enum InspectorError: Error, LocalizedError {
        case notFound(schema: String, table: String)
        var errorDescription: String? {
            switch self {
            case .notFound(let s, let t): "Relation \(s).\(t) not found"
            }
        }
    }
}
