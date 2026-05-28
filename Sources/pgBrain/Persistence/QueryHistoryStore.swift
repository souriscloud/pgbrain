import Foundation
import Observation

/// One row in the persisted query log. Captured each time the
/// `NotebookRunner` finishes a statement so users can browse what they
/// ran today, last week, or last quarter.
struct QueryHistoryEntry: Codable, Identifiable, Equatable {
    let id: UUID
    let connectionID: UUID
    let sql: String
    let startedAt: Date
    let elapsedSec: Double
    let success: Bool
    let errorMessage: String?
    let rowsAffected: Int?
}

/// JSON-backed append-only log of executed statements. Persisted to
/// `AppSupport/query_history.json`; debounced writes; capped at 5000
/// entries with FIFO eviction so the file doesn't grow forever.
@MainActor
@Observable
final class QueryHistoryStore {
    static let shared = QueryHistoryStore()

    private(set) var entries: [QueryHistoryEntry] = []
    @ObservationIgnored private var saveTask: Task<Void, Never>?
    @ObservationIgnored private let url: URL
    @ObservationIgnored private let maxEntries = 5000

    private init() {
        self.url = AppSupport.directory.appendingPathComponent("query_history.json")
        load()
    }

    func record(connectionID: UUID, sql: String, startedAt: Date,
                elapsedSec: Double, success: Bool,
                errorMessage: String?, rowsAffected: Int?) {
        let trimmed = sql.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        let entry = QueryHistoryEntry(
            id: UUID(), connectionID: connectionID,
            sql: trimmed, startedAt: startedAt,
            elapsedSec: elapsedSec, success: success,
            errorMessage: errorMessage, rowsAffected: rowsAffected
        )
        entries.append(entry)
        if entries.count > maxEntries {
            entries.removeFirst(entries.count - maxEntries)
        }
        scheduleSave()
    }

    func entries(for connectionID: UUID) -> [QueryHistoryEntry] {
        entries.filter { $0.connectionID == connectionID }.reversed()
    }

    func clear(for connectionID: UUID) {
        entries.removeAll { $0.connectionID == connectionID }
        scheduleSave()
    }

    private func scheduleSave() {
        saveTask?.cancel()
        saveTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 600_000_000)
            if Task.isCancelled { return }
            self?.flush()
        }
    }

    private func flush() {
        do {
            try AppSupport.ensureDirectoryExists()
            let data = try JSONEncoder().encode(entries)
            try data.write(to: url, options: .atomic)
        } catch {
            NSLog("pgBrain: QueryHistoryStore.flush failed: \(error)")
        }
    }

    private func load() {
        guard let data = try? Data(contentsOf: url),
              let decoded = try? JSONDecoder().decode([QueryHistoryEntry].self, from: data)
        else { return }
        entries = decoded
    }
}
