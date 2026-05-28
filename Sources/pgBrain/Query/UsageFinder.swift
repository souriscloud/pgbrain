import Foundation
import PostgresNIO

/// "Where is this table referenced?" — substring-match `schema.table`,
/// `"schema"."table"`, and bare `table` against the bodies of every
/// view, function, procedure, and trigger we can read. Heuristic by
/// design: a hand-rolled SQL parser would be more precise but the
/// schema-substring search catches 95%+ of usages with one catalog
/// query and zero dependencies.
struct UsageHit: Identifiable, Sendable {
    enum Kind: String, Sendable { case function, view, materializedView, trigger }
    var id: String { "\(kind.rawValue):\(schema).\(name)" }
    let kind: Kind
    let schema: String
    let name: String
    /// One-line excerpt of the definition around the match — purely a
    /// readability aid in the results pane.
    let excerpt: String
}

@MainActor
enum UsageFinder {
    static func find(schema: String, table: String, client: PostgresClient) async throws -> [UsageHit] {
        // We feed three forms to ILIKE so we catch quoted, schema-qual,
        // and bare-name references. Quoted-string escaping is hand-built
        // because the patterns contain `%` which isn't user-controlled.
        let bareSafe = escapeSQL(table)
        let qualSafe = escapeSQL("\(schema).\(table)")
        let funcSQL = """
        SELECT n.nspname, p.proname, 'function' AS kind, pg_get_functiondef(p.oid)
        FROM pg_proc p
        JOIN pg_namespace n ON n.oid = p.pronamespace
        WHERE n.nspname NOT IN ('pg_catalog','information_schema')
          AND (pg_get_functiondef(p.oid) ILIKE '%\(qualSafe)%'
            OR pg_get_functiondef(p.oid) ILIKE '%"\(bareSafe)"%'
            OR pg_get_functiondef(p.oid) ILIKE '% \(bareSafe) %'
            OR pg_get_functiondef(p.oid) ILIKE '% \(bareSafe)(%')
        """
        let viewSQL = """
        SELECT n.nspname, c.relname,
               CASE c.relkind WHEN 'm' THEN 'matview' ELSE 'view' END AS kind,
               pg_get_viewdef(c.oid)
        FROM pg_class c
        JOIN pg_namespace n ON n.oid = c.relnamespace
        WHERE c.relkind IN ('v','m')
          AND n.nspname NOT IN ('pg_catalog','information_schema')
          AND (pg_get_viewdef(c.oid) ILIKE '%\(qualSafe)%'
            OR pg_get_viewdef(c.oid) ILIKE '%"\(bareSafe)"%'
            OR pg_get_viewdef(c.oid) ILIKE '% \(bareSafe) %'
            OR pg_get_viewdef(c.oid) ILIKE '% \(bareSafe)(%')
        """
        let trigSQL = """
        SELECT n.nspname, t.tgname, 'trigger' AS kind, pg_get_triggerdef(t.oid)
        FROM pg_trigger t
        JOIN pg_class c ON c.oid = t.tgrelid
        JOIN pg_namespace n ON n.oid = c.relnamespace
        WHERE NOT t.tgisinternal
          AND pg_get_triggerdef(t.oid) ILIKE '%\(qualSafe)%'
        """
        async let funcs = fetch(sql: funcSQL, client: client)
        async let views = fetch(sql: viewSQL, client: client)
        async let trigs = fetch(sql: trigSQL, client: client)
        var out: [UsageHit] = []
        out.append(contentsOf: try await funcs)
        out.append(contentsOf: try await views)
        out.append(contentsOf: try await trigs)
        return out
    }

    private static func fetch(sql: String, client: PostgresClient) async throws -> [UsageHit] {
        let rows = try await client.query(PostgresQuery(unsafeSQL: sql))
        var out: [UsageHit] = []
        for try await (schema, name, kindStr, def) in rows.decode((String, String, String, String?).self) {
            let kind: UsageHit.Kind
            switch kindStr {
            case "function": kind = .function
            case "matview":  kind = .materializedView
            case "trigger":  kind = .trigger
            default:         kind = .view
            }
            out.append(UsageHit(
                kind: kind, schema: schema, name: name,
                excerpt: previewExcerpt(def)
            ))
        }
        return out
    }

    private static func previewExcerpt(_ s: String?) -> String {
        guard let s else { return "" }
        let collapsed = s.components(separatedBy: .whitespacesAndNewlines)
            .filter { !$0.isEmpty }
            .joined(separator: " ")
        return collapsed.count > 200 ? String(collapsed.prefix(200)) + "…" : collapsed
    }

    private static func escapeSQL(_ s: String) -> String {
        // Escape single-quote AND LIKE metacharacters so the pattern is
        // literal — without this a table containing '%' would over-match.
        s.replacingOccurrences(of: "'", with: "''")
         .replacingOccurrences(of: "%", with: "\\%")
         .replacingOccurrences(of: "_", with: "\\_")
    }
}
