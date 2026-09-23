import Foundation
import PostgresNIO

/// Every foreign key of one table, including multi-column ones (the schema
/// snapshot's `TableNode.foreignKeys` only carries single-column keys).
/// Fetched lazily the first time the user ⌘-clicks a cell.
enum ForeignKeyResolver {
    struct Key: Equatable, Sendable {
        let name: String
        let localColumns: [String]
        let refSchema: String
        let refTable: String
        let refColumns: [String]
    }

    static func fetch(client: PostgresClient, schema: String, table: String) async throws -> [Key] {
        let sql: PostgresQuery = """
        SELECT con.conname::text,
               n2.nspname::text,
               c2.relname::text,
               array_agg(a1.attname::text ORDER BY k.ord),
               array_agg(a2.attname::text ORDER BY k.ord)
        FROM pg_constraint con
        JOIN pg_class c1 ON c1.oid = con.conrelid
        JOIN pg_namespace n1 ON n1.oid = c1.relnamespace
        JOIN pg_class c2 ON c2.oid = con.confrelid
        JOIN pg_namespace n2 ON n2.oid = c2.relnamespace
        CROSS JOIN LATERAL unnest(con.conkey, con.confkey) WITH ORDINALITY AS k(l, r, ord)
        JOIN pg_attribute a1 ON a1.attrelid = con.conrelid AND a1.attnum = k.l
        JOIN pg_attribute a2 ON a2.attrelid = con.confrelid AND a2.attnum = k.r
        WHERE con.contype = 'f' AND n1.nspname = \(schema) AND c1.relname = \(table)
        GROUP BY con.conname, n2.nspname, c2.relname
        ORDER BY con.conname
        """
        let rows = try await client.query(sql)
        var out: [Key] = []
        for try await (name, rschema, rtable, local, ref) in rows.decode((String, String, String, [String], [String]).self) {
            out.append(Key(name: name, localColumns: local, refSchema: rschema, refTable: rtable, refColumns: ref))
        }
        return out
    }

    /// The key to follow from a click on `column`: a single-column key on it
    /// wins over a composite one that merely includes it.
    static func key(for column: String, in keys: [Key]) -> Key? {
        keys.first { $0.localColumns == [column] } ?? keys.first { $0.localColumns.contains(column) }
    }

    /// `WHERE` body selecting the referenced row(s) for a child row's key
    /// values (`values[i]` belongs to `key.localColumns[i]`). A NULL
    /// component matches with `IS NULL` — MATCH SIMPLE keys may carry one.
    static func whereClause(for key: Key, values: [String?], refTypes: [String: String]) -> String {
        zip(key.refColumns, values).map { column, value in
            let quoted = SQLIdent.quote(column)
            guard let value else { return "\(quoted) IS NULL" }
            let literal = refTypes[column].map { UpdateApplier.typedLiteral(value, typeName: $0) }
                ?? UpdateApplier.quoteLiteral(value)
            return "\(quoted) = \(literal)"
        }
        .joined(separator: " AND ")
    }
}
