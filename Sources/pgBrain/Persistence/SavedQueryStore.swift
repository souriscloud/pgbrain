import Foundation
import Observation

/// User's library of saved SQL snippets. Persisted to
/// `~/Library/Application Support/pgBrain/saved-queries.json`. Cross-cuts
/// every connection — a saved query is reusable text, not bound to a
/// specific database.
struct SavedQuery: Identifiable, Codable, Hashable {
    var id: UUID = UUID()
    var name: String
    var notes: String = ""
    var sql: String
    var createdAt: Date = Date()
    var updatedAt: Date = Date()
}

@MainActor
@Observable
final class SavedQueryStore {
    static let shared = SavedQueryStore()

    private(set) var queries: [SavedQuery] = []

    /// Non-nil only in tests (DEBUG seam) so `swift test` writes to an
    /// isolated file instead of the real library.
    @ObservationIgnored private let overrideURL: URL?

    private init() {
        self.overrideURL = nil
        load()
    }

    #if DEBUG
    init(testURL: URL) {
        self.overrideURL = testURL
        load()
    }
    /// `persist()` is async; this lets a test write synchronously then assert.
    func flushNowForTests() {
        try? AppSupport.ensureDirectoryExists()
        if let data = try? JSONEncoder().encode(queries) {
            try? data.write(to: fileURL, options: .atomic)
        }
    }
    #endif

    private var fileURL: URL {
        overrideURL ?? AppSupport.directory.appendingPathComponent("saved-queries.json")
    }

    func load() {
        guard let data = try? Data(contentsOf: fileURL),
              let decoded = try? JSONDecoder().decode([SavedQuery].self, from: data)
        else { return }
        queries = decoded
    }

    func upsert(_ query: SavedQuery) {
        var copy = query
        copy.updatedAt = Date()
        if let i = queries.firstIndex(where: { $0.id == copy.id }) {
            queries[i] = copy
        } else {
            queries.insert(copy, at: 0)
        }
        persist()
    }

    func remove(id: UUID) {
        queries.removeAll { $0.id == id }
        persist()
    }

    /// Saved query matching the search term in name, notes, or SQL body.
    /// Case-insensitive, substring match — good enough for a single-user
    /// library. If we ever ship a "team library" feature, swap to a trie.
    func matching(_ term: String) -> [SavedQuery] {
        guard !term.isEmpty else { return queries }
        let needle = term.lowercased()
        return queries.filter {
            $0.name.lowercased().contains(needle)
                || $0.notes.lowercased().contains(needle)
                || $0.sql.lowercased().contains(needle)
        }
    }

    private func persist() {
        let snapshot = queries
        let url = fileURL
        DispatchQueue.global(qos: .utility).async {
            do {
                try AppSupport.ensureDirectoryExists()
                let data = try JSONEncoder().encode(snapshot)
                try data.write(to: url, options: .atomic)
            } catch {
                // Best-effort.
            }
        }
    }
}
