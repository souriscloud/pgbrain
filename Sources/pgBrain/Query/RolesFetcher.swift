import Foundation
import PostgresNIO

/// One row from `pg_roles` — every role in the cluster, login or
/// otherwise. The Activity panel's Roles tab renders these so DBAs
/// can see at a glance who can log in / who's a superuser.
struct RoleRow: Identifiable, Sendable {
    var id: String { name }
    let name: String
    let isSuperuser: Bool
    let canLogin: Bool
    let canCreateDB: Bool
    let canCreateRole: Bool
    let inherit: Bool
    let connectionLimit: Int
    /// Comma-joined list of memberOf role names.
    let memberOf: String
}

/// One row from `information_schema.role_table_grants` — who has what
/// privilege on which table. We aggregate the privileges per
/// (grantee, schema, table) so a role with SELECT+INSERT shows as one
/// row with "SELECT, INSERT".
struct GrantRow: Identifiable, Sendable {
    var id: String { "\(grantee).\(schema).\(table)" }
    let grantee: String
    let schema: String
    let table: String
    let privileges: String
}

@MainActor
enum RolesFetcher {
    static func fetchRoles(client: PostgresClient) async throws -> [RoleRow] {
        // `pg_roles` masks the password hash so we can read it without
        // the superuser dance `pg_authid` would need.
        let sql: PostgresQuery = """
        SELECT r.rolname,
               r.rolsuper,
               r.rolcanlogin,
               r.rolcreatedb,
               r.rolcreaterole,
               r.rolinherit,
               r.rolconnlimit::int,
               coalesce((
                  SELECT string_agg(g.rolname, ', ' ORDER BY g.rolname)
                  FROM pg_auth_members m
                  JOIN pg_roles g ON g.oid = m.roleid
                  WHERE m.member = r.oid
               ), '') AS member_of
        FROM pg_roles r
        ORDER BY r.rolname
        """
        let rows = try await client.query(sql)
        var out: [RoleRow] = []
        for try await (name, sup, login, ccdb, ccrole, inh, climit, memb)
            in rows.decode((String, Bool, Bool, Bool, Bool, Bool, Int, String).self) {
            out.append(RoleRow(
                name: name, isSuperuser: sup, canLogin: login,
                canCreateDB: ccdb, canCreateRole: ccrole, inherit: inh,
                connectionLimit: climit, memberOf: memb
            ))
        }
        return out
    }

    static func fetchGrants(client: PostgresClient) async throws -> [GrantRow] {
        // information_schema flattens grants to one row per
        // (grantee, table, privilege). We aggregate in SQL to keep the
        // payload small even on large permissioning surfaces.
        let sql: PostgresQuery = """
        SELECT grantee,
               table_schema,
               table_name,
               string_agg(privilege_type, ', ' ORDER BY privilege_type) AS privileges
        FROM information_schema.role_table_grants
        WHERE table_schema NOT IN ('pg_catalog','information_schema')
        GROUP BY grantee, table_schema, table_name
        ORDER BY grantee, table_schema, table_name
        """
        let rows = try await client.query(sql)
        var out: [GrantRow] = []
        for try await (grantee, schema, table, privs)
            in rows.decode((String, String, String, String).self) {
            out.append(GrantRow(grantee: grantee, schema: schema, table: table, privileges: privs))
        }
        return out
    }
}
