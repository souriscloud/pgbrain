import Foundation

/// Translates psql-style slash commands (`\d table`, `\dt`, `\dn`, …)
/// into the underlying catalog SELECT. Statement-level only — a cell
/// is preprocessed line-by-line, with non-`\` lines passed through
/// unchanged. Lets long-time psql users get to data with the keystrokes
/// they already type without leaving the GUI.
///
/// Coverage tracks psql's most-used set. Anything we don't know we
/// leave alone (the runner will surface the syntax error so the user
/// learns we don't support it yet).
enum SlashCommands {
    /// Translate `input` if it's a single recognised slash command,
    /// otherwise return `input` unchanged. Whitespace-trimmed on entry.
    static func translate(_ input: String) -> String {
        let trimmed = input.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.hasPrefix("\\") else { return input }
        // Strip leading backslash and split.
        let body = String(trimmed.dropFirst())
        let parts = body.split(separator: " ", maxSplits: 1, omittingEmptySubsequences: true)
        guard let head = parts.first else { return input }
        let arg = parts.count > 1 ? String(parts[1]) : ""

        switch String(head) {
        case "l", "list":
            return """
            SELECT d.datname AS name,
                   pg_get_userbyid(d.datdba) AS owner,
                   pg_encoding_to_char(d.encoding) AS encoding,
                   d.datcollate AS collation,
                   pg_size_pretty(pg_database_size(d.datname)) AS size
            FROM pg_database d
            WHERE NOT d.datistemplate
            ORDER BY d.datname
            """
        case "dn":
            return """
            SELECT n.nspname AS schema,
                   pg_get_userbyid(n.nspowner) AS owner
            FROM pg_namespace n
            WHERE n.nspname NOT LIKE 'pg_temp_%'
              AND n.nspname NOT LIKE 'pg_toast%'
            ORDER BY n.nspname
            """
        case "du":
            return """
            SELECT r.rolname AS role,
                   r.rolsuper AS superuser,
                   r.rolinherit AS inherit,
                   r.rolcreaterole AS create_role,
                   r.rolcreatedb AS create_db,
                   r.rolcanlogin AS login,
                   r.rolconnlimit AS conn_limit
            FROM pg_roles r
            ORDER BY r.rolname
            """
        case "dt":
            return relationListing(kinds: "('r','p')", filter: arg)
        case "dv":
            return relationListing(kinds: "('v')", filter: arg)
        case "dm":
            return relationListing(kinds: "('m')", filter: arg)
        case "di":
            return """
            SELECT n.nspname AS schema,
                   c.relname AS name,
                   t.relname AS table,
                   pg_get_userbyid(c.relowner) AS owner
            FROM pg_class c
            JOIN pg_namespace n ON n.oid = c.relnamespace
            JOIN pg_index x ON x.indexrelid = c.oid
            JOIN pg_class t ON t.oid = x.indrelid
            WHERE c.relkind = 'i'
              AND n.nspname NOT IN ('pg_catalog','information_schema')
            ORDER BY n.nspname, c.relname
            """
        case "ds":
            return """
            SELECT s.schemaname AS schema,
                   s.sequencename AS name,
                   s.last_value
            FROM pg_sequences s
            WHERE s.schemaname NOT IN ('pg_catalog','information_schema')
            ORDER BY s.schemaname, s.sequencename
            """
        case "df":
            return """
            SELECT n.nspname AS schema,
                   p.proname AS name,
                   pg_get_function_result(p.oid) AS result,
                   pg_get_function_arguments(p.oid) AS arguments,
                   CASE p.prokind WHEN 'f' THEN 'func'
                                  WHEN 'p' THEN 'proc'
                                  WHEN 'a' THEN 'agg'
                                  WHEN 'w' THEN 'window'
                                  ELSE p.prokind::text END AS kind
            FROM pg_proc p
            JOIN pg_namespace n ON n.oid = p.pronamespace
            WHERE n.nspname NOT IN ('pg_catalog','information_schema')
            ORDER BY n.nspname, p.proname
            """
        case "dx":
            return """
            SELECT e.extname AS name,
                   e.extversion AS version,
                   n.nspname AS schema,
                   c.description
            FROM pg_extension e
            JOIN pg_namespace n ON n.oid = e.extnamespace
            LEFT JOIN pg_description c
                   ON c.objoid = e.oid AND c.classoid = 'pg_extension'::regclass
            ORDER BY e.extname
            """
        case "d", "d+":
            return describeRelation(arg)
        default:
            return input
        }
    }

    /// Walks the cell's text and translates any line that's a standalone
    /// slash command, leaving everything else untouched. Cell-mode for
    /// multi-statement cells where a `\dt` line lives next to actual SQL.
    static func translateCell(_ text: String) -> String {
        let lines = text.split(separator: "\n", omittingEmptySubsequences: false)
        var out: [String] = []
        for line in lines {
            let s = String(line)
            let trimmed = s.trimmingCharacters(in: .whitespaces)
            if trimmed.hasPrefix("\\") {
                out.append(translate(trimmed))
            } else {
                out.append(s)
            }
        }
        return out.joined(separator: "\n")
    }

    // MARK: - Helpers

    private static func relationListing(kinds: String, filter: String) -> String {
        let where_: String
        if filter.isEmpty {
            where_ = "AND n.nspname NOT IN ('pg_catalog','information_schema')"
        } else {
            // Treat `schema.something` as schema-qualified, else just match
            // names case-insensitively across user schemas.
            if filter.contains(".") {
                let parts = filter.split(separator: ".", maxSplits: 1).map(String.init)
                let schemaLit = sqlString(parts[0])
                let nameLit = sqlString(parts[1])
                where_ = "AND n.nspname = \(schemaLit) AND c.relname ILIKE \(nameLit)"
            } else {
                let nameLit = sqlString(filter)
                where_ = "AND n.nspname NOT IN ('pg_catalog','information_schema') AND c.relname ILIKE \(nameLit)"
            }
        }
        return """
        SELECT n.nspname AS schema,
               c.relname AS name,
               c.relkind::text AS kind,
               pg_get_userbyid(c.relowner) AS owner,
               pg_size_pretty(pg_total_relation_size(c.oid)) AS size
        FROM pg_class c
        JOIN pg_namespace n ON n.oid = c.relnamespace
        WHERE c.relkind IN \(kinds)
          \(where_)
        ORDER BY n.nspname, c.relname
        """
    }

    /// `\d name` — show the columns of a named relation. We use
    /// `format_type` for the type and join `pg_attrdef` for defaults.
    private static func describeRelation(_ name: String) -> String {
        guard !name.isEmpty else {
            // Bare `\d` lists all tables / views / matviews / sequences.
            return relationListing(kinds: "('r','p','v','m','S')", filter: "")
        }
        let lit = sqlString(name)
        return """
        SELECT a.attnum::int AS "#",
               a.attname AS name,
               format_type(a.atttypid, a.atttypmod) AS type,
               (NOT a.attnotnull) AS nullable,
               pg_get_expr(d.adbin, d.adrelid) AS default,
               col_description(a.attrelid, a.attnum) AS comment
        FROM pg_attribute a
        LEFT JOIN pg_attrdef d ON d.adrelid = a.attrelid AND d.adnum = a.attnum
        WHERE a.attrelid = \(lit)::regclass
          AND a.attnum > 0
          AND NOT a.attisdropped
        ORDER BY a.attnum
        """
    }

    private static func sqlString(_ s: String) -> String {
        "'" + s.replacingOccurrences(of: "'", with: "''") + "'"
    }
}
