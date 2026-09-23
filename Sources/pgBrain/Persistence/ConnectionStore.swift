import Foundation
import Observation

/// JSON-backed store for connection metadata (everything except the password).
@MainActor
@Observable
final class ConnectionStore {
    static let shared = ConnectionStore()

    private(set) var connections: [Connection] = []

    private let url: URL

    private init() {
        self.url = AppSupport.connectionsFile
        load()
    }

    #if DEBUG
    init(testURL: URL) {
        self.url = testURL
        load()
    }
    #endif

    /// Outcome of decoding connections.json, split out so the salvage logic
    /// is unit-testable without touching disk.
    struct DecodeResult {
        var connections: [Connection]
        /// Elements (or the whole file) that could not be decoded. Non-zero
        /// means the next save would lose data, so the file gets backed up.
        var droppedCount: Int
        var fileUnreadable: Bool
    }

    /// Decode element by element: one bad entry must not take the whole list
    /// down with it.
    nonisolated static func decode(_ data: Data) -> DecodeResult {
        guard let raw = try? JSONSerialization.jsonObject(with: data) as? [Any] else {
            return DecodeResult(connections: [], droppedCount: 0, fileUnreadable: true)
        }
        var out: [Connection] = []
        var dropped = 0
        let decoder = JSONDecoder()
        for element in raw {
            // `data(withJSONObject:)` raises (not throws) on a bare scalar,
            // so only dictionaries get this far.
            guard let dict = element as? [String: Any],
                  JSONSerialization.isValidJSONObject(dict),
                  let elementData = try? JSONSerialization.data(withJSONObject: dict),
                  let connection = try? decoder.decode(Connection.self, from: elementData) else {
                dropped += 1
                continue
            }
            out.append(connection)
        }
        return DecodeResult(connections: out, droppedCount: dropped, fileUnreadable: false)
    }

    func load() {
        guard let data = try? Data(contentsOf: url) else {
            connections = []
            return
        }
        let result = Self.decode(data)
        connections = result.connections
        if result.fileUnreadable || result.droppedCount > 0 {
            Log.persistence.error("connections.json: \(result.droppedCount, privacy: .public) undecodable entries, unreadable=\(result.fileUnreadable, privacy: .public); backing up before any rewrite")
            backUpCurrentFile()
        }
    }

    /// Copy the on-disk file aside as `connections.json.bak-<timestamp>`.
    /// Returns the backup URL (nil when nothing was copied).
    @discardableResult
    func backUpCurrentFile() -> URL? {
        guard FileManager.default.fileExists(atPath: url.path) else { return nil }
        let stamp = Self.backupStampFormatter.string(from: Date())
        var backup = url.deletingLastPathComponent()
            .appendingPathComponent("\(url.lastPathComponent).bak-\(stamp)")
        var n = 1
        while FileManager.default.fileExists(atPath: backup.path) {
            n += 1
            backup = url.deletingLastPathComponent()
                .appendingPathComponent("\(url.lastPathComponent).bak-\(stamp)-\(n)")
        }
        do {
            try FileManager.default.copyItem(at: url, to: backup)
            return backup
        } catch {
            Log.persistence.error("failed to back up connections.json: \(error.localizedDescription, privacy: .public)")
            return nil
        }
    }

    private static let backupStampFormatter: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyyMMdd-HHmmss"
        return f
    }()

    func save() {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        do {
            let data = try encoder.encode(connections)
            try data.write(to: url, options: [.atomic])
        } catch {
            Log.persistence.error("failed to save connections: \(error.localizedDescription, privacy: .public)")
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

    /// Fill Keychain passwords from parsed `~/.pgpass` entries for saved
    /// connections that don't have one yet. Existing passwords are never
    /// overwritten. Returns how many connections got a password.
    @discardableResult
    func fillPasswords(from pgpass: [ConnInfoParser.PgPassEntry],
                       hasPassword: (UUID) -> Bool = { Keychain.password(for: $0) != nil },
                       store: (String, UUID) throws -> Void = { try Keychain.setPassword($0, for: $1) }) -> Int {
        var filled = 0
        for c in connections where !hasPassword(c.id) {
            guard let pw = ConnInfoParser.pgpassLookup(pgpass, host: c.host, port: c.port,
                                                       database: c.database.isEmpty ? c.username : c.database,
                                                       user: c.username) else { continue }
            do {
                try store(pw, c.id)
                filled += 1
            } catch {
                Log.persistence.error("pgpass fill failed: \(String(describing: error), privacy: .public)")
            }
        }
        return filled
    }
}
