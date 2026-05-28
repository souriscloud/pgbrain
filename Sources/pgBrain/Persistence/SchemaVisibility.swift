import Foundation
import Observation

/// Per-connection set of schemas hidden from the sidebar tree, the
/// command palette, and the autocomplete provider. Backed by
/// `UserDefaults` so the choice survives relaunches without polluting
/// the on-disk session JSON.
///
/// We keep this global (rather than wiring it onto `ConnectionService`)
/// so views that don't have a service handle — e.g. the connection
/// editor sheet — can still query it.
@MainActor
@Observable
final class SchemaVisibility {
    static let shared = SchemaVisibility()

    /// Map: connection-UUID → hidden schemas. Stored as
    /// `[connectionID: [schemaName]]` JSON in UserDefaults.
    private(set) var hidden: [UUID: Set<String>] = [:]

    private let key = "pgbrain.schemaVisibility.hidden"
    @ObservationIgnored private let defaults = UserDefaults.standard

    private init() {
        load()
    }

    /// Hidden schemas for a connection, or empty set when nothing
    /// is configured. Callers should treat membership as "skip this
    /// schema everywhere user-facing".
    func hidden(for connectionID: UUID) -> Set<String> {
        hidden[connectionID] ?? []
    }

    func isHidden(_ schema: String, connectionID: UUID) -> Bool {
        hidden(for: connectionID).contains(schema)
    }

    func setHidden(_ value: Bool, schema: String, connectionID: UUID) {
        var current = hidden[connectionID] ?? []
        if value { current.insert(schema) } else { current.remove(schema) }
        if current.isEmpty {
            hidden.removeValue(forKey: connectionID)
        } else {
            hidden[connectionID] = current
        }
        save()
    }

    func toggle(schema: String, connectionID: UUID) {
        setHidden(!isHidden(schema, connectionID: connectionID),
                  schema: schema, connectionID: connectionID)
    }

    func clear(connectionID: UUID) {
        hidden.removeValue(forKey: connectionID)
        save()
    }

    // MARK: - Persistence

    private func load() {
        guard let raw = defaults.data(forKey: key),
              let decoded = try? JSONDecoder().decode([String: [String]].self, from: raw)
        else { return }
        var out: [UUID: Set<String>] = [:]
        for (idString, names) in decoded {
            if let id = UUID(uuidString: idString) {
                out[id] = Set(names)
            }
        }
        self.hidden = out
    }

    private func save() {
        var encoded: [String: [String]] = [:]
        for (id, set) in hidden {
            encoded[id.uuidString] = Array(set).sorted()
        }
        guard let data = try? JSONEncoder().encode(encoded) else { return }
        defaults.set(data, forKey: key)
    }
}
