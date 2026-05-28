import Foundation
import PostgresNIO

/// Logical/physical replication overview — publications, subscriptions,
/// and replication slots. Read-only; the Activity panel's Replication
/// tab renders these so a DBA can sanity-check a logical-replication
/// setup without dropping to psql.
struct PublicationRow: Identifiable, Sendable {
    var id: String { name }
    let name: String
    let owner: String
    let allTables: Bool
    let insert: Bool
    let update: Bool
    let delete: Bool
    let truncate: Bool
}

struct SubscriptionRow: Identifiable, Sendable {
    var id: String { name }
    let name: String
    let enabled: Bool
    let publications: String
    let workerCount: Int
}

struct ReplicationSlotRow: Identifiable, Sendable {
    var id: String { name }
    let name: String
    let slotType: String
    let active: Bool
    let database: String?
    let plugin: String?
}

@MainActor
enum ReplicationFetcher {
    static func publications(client: PostgresClient) async throws -> [PublicationRow] {
        let sql: PostgresQuery = """
        SELECT p.pubname,
               pg_get_userbyid(p.pubowner),
               p.puballtables,
               p.pubinsert,
               p.pubupdate,
               p.pubdelete,
               p.pubtruncate
        FROM pg_publication p
        ORDER BY p.pubname
        """
        let rows = try await client.query(sql)
        var out: [PublicationRow] = []
        for try await (name, owner, all, ins, upd, del, trunc)
            in rows.decode((String, String, Bool, Bool, Bool, Bool, Bool).self) {
            out.append(PublicationRow(
                name: name, owner: owner, allTables: all,
                insert: ins, update: upd, delete: del, truncate: trunc
            ))
        }
        return out
    }

    static func subscriptions(client: PostgresClient) async throws -> [SubscriptionRow] {
        // pg_subscription is superuser-only readable; we catch the
        // permission error upstream and show an empty tab.
        let sql: PostgresQuery = """
        SELECT s.subname,
               s.subenabled,
               array_to_string(s.subpublications, ', '),
               coalesce((SELECT count(*)::int FROM pg_stat_subscription ss WHERE ss.subid = s.oid), 0)
        FROM pg_subscription s
        ORDER BY s.subname
        """
        let rows = try await client.query(sql)
        var out: [SubscriptionRow] = []
        for try await (name, enabled, pubs, workers)
            in rows.decode((String, Bool, String, Int).self) {
            out.append(SubscriptionRow(name: name, enabled: enabled, publications: pubs, workerCount: workers))
        }
        return out
    }

    static func slots(client: PostgresClient) async throws -> [ReplicationSlotRow] {
        let sql: PostgresQuery = """
        SELECT slot_name,
               slot_type,
               active,
               database,
               plugin
        FROM pg_replication_slots
        ORDER BY slot_name
        """
        let rows = try await client.query(sql)
        var out: [ReplicationSlotRow] = []
        for try await (name, type, active, db, plugin)
            in rows.decode((String, String, Bool, String?, String?).self) {
            out.append(ReplicationSlotRow(name: name, slotType: type, active: active, database: db, plugin: plugin))
        }
        return out
    }
}

/// Foreign-data-wrapper overview: servers, wrappers, and foreign
/// tables. Read-only.
struct ForeignServerRow: Identifiable, Sendable {
    var id: String { name }
    let name: String
    let wrapper: String
    let owner: String
    let type: String?
    let version: String?
}

struct ForeignTableRow: Identifiable, Sendable {
    var id: String { "\(schema).\(name)" }
    let schema: String
    let name: String
    let server: String
}

@MainActor
enum ForeignDataFetcher {
    static func servers(client: PostgresClient) async throws -> [ForeignServerRow] {
        let sql: PostgresQuery = """
        SELECT s.srvname,
               w.fdwname,
               pg_get_userbyid(s.srvowner),
               s.srvtype,
               s.srvversion
        FROM pg_foreign_server s
        JOIN pg_foreign_data_wrapper w ON w.oid = s.srvfdw
        ORDER BY s.srvname
        """
        let rows = try await client.query(sql)
        var out: [ForeignServerRow] = []
        for try await (name, wrapper, owner, type, version)
            in rows.decode((String, String, String, String?, String?).self) {
            out.append(ForeignServerRow(name: name, wrapper: wrapper, owner: owner, type: type, version: version))
        }
        return out
    }

    static func tables(client: PostgresClient) async throws -> [ForeignTableRow] {
        let sql: PostgresQuery = """
        SELECT n.nspname,
               c.relname,
               s.srvname
        FROM pg_foreign_table ft
        JOIN pg_class c ON c.oid = ft.ftrelid
        JOIN pg_namespace n ON n.oid = c.relnamespace
        JOIN pg_foreign_server s ON s.oid = ft.ftserver
        ORDER BY n.nspname, c.relname
        """
        let rows = try await client.query(sql)
        var out: [ForeignTableRow] = []
        for try await (schema, name, server) in rows.decode((String, String, String).self) {
            out.append(ForeignTableRow(schema: schema, name: name, server: server))
        }
        return out
    }
}
