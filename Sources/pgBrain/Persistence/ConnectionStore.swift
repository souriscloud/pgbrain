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
}
