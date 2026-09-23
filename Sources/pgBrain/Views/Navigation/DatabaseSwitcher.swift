import PostgresNIO
import SwiftUI

/// Lists the connectable databases on the server for the chrome-bar switcher
/// and the breadcrumb. Pure entrypoint so it's E2E-testable.
enum DatabaseCatalog {
    static func fetchDatabases(client: PostgresClient) async throws -> [String] {
        let rows = try await client.query("""
            SELECT datname FROM pg_database
            WHERE datallowconn AND NOT datistemplate
            ORDER BY datname
            """)
        var out: [String] = []
        for try await name in rows.decode(String.self) { out.append(name) }
        return out
    }
}

/// Chrome-bar dropdown showing the window's database. Picking another one
/// opens (or focuses) a sibling window for the same connection on that
/// database — ConnectionService stays one-database-per-window.
struct DatabaseSwitcherMenu: View {
    let service: ConnectionService
    let databases: [String]
    let foreground: Color
    let onRefresh: () -> Void
    let onNewDatabase: () -> Void

    private var current: String {
        let name = service.schema.databaseName
        if !name.isEmpty { return name }
        return service.connection.database.isEmpty ? service.connection.host : service.connection.database
    }

    var body: some View {
        Menu {
            Section("Open database") {
                ForEach(databases, id: \.self) { db in
                    Button {
                        open(db)
                    } label: {
                        Label(db, systemImage: db == current ? "checkmark" : (isOpenElsewhere(db) ? "macwindow" : ""))
                    }
                }
            }
            if databases.isEmpty {
                Text("No database list yet").foregroundStyle(.secondary)
            }
            Divider()
            Button("New Database…", action: onNewDatabase)
            Button("Refresh List", action: onRefresh)
        } label: {
            HStack(spacing: 3) {
                Image(systemName: "cylinder.split.1x2")
                Text(current)
            }
            .font(.caption2.weight(.medium))
            .foregroundStyle(foreground)
        }
        .menuStyle(.borderlessButton)
        .fixedSize()
        .help("Switch database — opens it in a sibling window")
    }

    private func isOpenElsewhere(_ db: String) -> Bool {
        AppDelegate.shared?.windowManager.openDatabases(for: service.connection.id).contains(db) ?? false
    }

    private func open(_ db: String) {
        guard db != current else { return }
        AppDelegate.shared?.openConnection(service.connection, database: db)
    }
}
