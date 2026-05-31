import Foundation
import Observation

/// JSON-backed store for connection metadata (everything except the password).
@MainActor
@Observable
final class ConnectionStore {
    static let shared = ConnectionStore()

    private(set) var connections: [Connection] = []

    private let url = AppSupport.connectionsFile

    private init() {
        load()
    }

    func load() {
        guard let data = try? Data(contentsOf: url) else {
            connections = []
            return
        }
        let decoder = JSONDecoder()
        connections = (try? decoder.decode([Connection].self, from: data)) ?? []
    }

    func save() {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        do {
            let data = try encoder.encode(connections)
            try data.write(to: url, options: [.atomic])
        } catch {
            NSLog("pgBrain: failed to save connections: \(error)")
        }
    }

    func upsert(_ connection: Connection) {
        if let idx = connections.firstIndex(where: { $0.id == connection.id }) {
            connections[idx] = connection
        } else {
            connections.append(connection)
        }
        save()
    }

    func remove(_ connection: Connection) {
        connections.removeAll { $0.id == connection.id }
        Keychain.deletePassword(for: connection.id)
        save()
    }

    func connection(id: UUID) -> Connection? {
        connections.first { $0.id == id }
    }

    /// Import parsed connections as NEW entries (fresh UUIDs), skipping any
    /// that exactly match an existing connection (same name/host/port/db/
    /// user) so re-importing a backup doesn't pile up duplicates. Stores any
    /// included password in the Keychain. Returns the count actually added.
    @discardableResult
    func importConnections(_ items: [ConnectionExchange.Imported]) -> Int {
        var added = 0
        for item in items {
            let c = item.connection
            let isDuplicate = connections.contains {
                $0.name == c.name && $0.host == c.host && $0.port == c.port
                    && $0.database == c.database && $0.username == c.username
            }
            if isDuplicate { continue }
            upsert(c)
            if let pw = item.password, !pw.isEmpty {
                try? Keychain.setPassword(pw, for: c.id)
            }
            added += 1
        }
        return added
    }
}
