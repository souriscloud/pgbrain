import Foundation
import Observation

/// One row in the persisted query log. Captured each time the
/// `NotebookRunner` finishes a statement so users can browse what they
/// ran today, last week, or last quarter.
struct QueryHistoryEntry: Codable, Identifiable, Equatable, Sendable {
    let id: UUID
    let connectionID: UUID
    let sql: String
    let startedAt: Date
    let elapsedSec: Double
    let success: Bool
    let errorMessage: String?
    let rowsAffected: Int?
}

/// Strips secrets from SQL before it's written to disk.
enum QueryHistoryRedactor {
    static let mask = "'********'"

    private static let rules: [(NSRegularExpression, String)] = {
        func re(_ pattern: String) -> NSRegularExpression {
            // Patterns are literals; a failure here is a programmer error.
            try! NSRegularExpression(pattern: pattern, options: [.caseInsensitive, .dotMatchesLineSeparators])
        }
        // Group 2 is the dollar-quote tag (group 1 is the PASSWORD prefix).
        let quoted = #"(?:E'(?:[^'\\]|\\.|'')*'|'(?:[^']|'')*'|\$([A-Za-z_]*)\$.*?\$\2\$)"#
        return [
            // ALTER ROLE … PASSWORD '…', CREATE USER … PASSWORD '…',
            // OPTIONS (password '…') on user mappings / FDW servers.
            (re(#"(\bPASSWORD\s+)"# + quoted), "$1" + mask),
            // Conninfo inside literals: dblink('… password=secret …').
            (re(#"(\bpassword\s*=\s*)('[^']*'|[^\s']+)"#), "$1********"),
            // postgres://user:secret@host
            (re(#"(\b(?:postgres|postgresql)://[^:/@\s']*:)[^@\s']*(@)"#), "$1********$2"),
        ]
    }()

    static func redact(_ sql: String) -> String {
        guard sql.range(of: "password", options: .caseInsensitive) != nil || sql.contains("://") else {
            return sql
        }
        var out = sql
        for (regex, template) in rules {
            let range = NSRange(out.startIndex..., in: out)
            out = regex.stringByReplacingMatches(in: out, range: range, withTemplate: template)
        }
        return out
    }
}

/// JSON-backed append-only log of executed statements. Persisted to
/// `AppSupport/query_history.json`; debounced writes encoded off the main
/// actor; capped at 5000 entries with FIFO eviction.
@MainActor
@Observable
final class QueryHistoryStore {
    static let shared = QueryHistoryStore()

    private(set) var entries: [QueryHistoryEntry] = []
    @ObservationIgnored private var saveTask: Task<Void, Never>?
    @ObservationIgnored private var dirty = false
    @ObservationIgnored private let url: URL
    @ObservationIgnored private let maxEntries = 5000
    @ObservationIgnored private let writeQueue = DispatchQueue(label: "cloud.souris.pgbrain.query-history", qos: .utility)
    @ObservationIgnored private let isEnabled: @MainActor () -> Bool

    private init() {
        self.url = AppSupport.directory.appendingPathComponent("query_history.json")
        self.isEnabled = { AppSettings.shared.saveQueryHistory }
        load()
    }

    #if DEBUG
    init(testURL: URL, isEnabled: @escaping @MainActor () -> Bool = { true }) {
        self.url = testURL
        self.isEnabled = isEnabled
        load()
    }
    func flushNowForTests() { flushNow() }
    #endif

    func record(connectionID: UUID, sql: String, startedAt: Date,
                elapsedSec: Double, success: Bool,
                errorMessage: String?, rowsAffected: Int?) {
        guard isEnabled() else { return }
        let trimmed = sql.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        let entry = QueryHistoryEntry(
            id: UUID(), connectionID: connectionID,
            sql: QueryHistoryRedactor.redact(trimmed), startedAt: startedAt,
            elapsedSec: elapsedSec, success: success,
            errorMessage: errorMessage.map(QueryHistoryRedactor.redact), rowsAffected: rowsAffected
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

    func clearAll() {
        entries.removeAll()
        scheduleSave()
    }

    private func scheduleSave() {
        dirty = true
        saveTask?.cancel()
        saveTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 600_000_000)
            if Task.isCancelled { return }
            self?.flushInBackground()
        }
    }

    private func flushInBackground() {
        guard dirty else { return }
        dirty = false
        let snapshot = entries
        let url = url
        writeQueue.async { Self.write(snapshot, to: url) }
    }

    /// Write pending changes before returning. Used at app termination.
    func flushNow() {
        saveTask?.cancel()
        saveTask = nil
        if dirty {
            dirty = false
            let snapshot = entries
            let url = url
            writeQueue.async { Self.write(snapshot, to: url) }
        }
        writeQueue.sync {}
    }

    nonisolated private static func write(_ entries: [QueryHistoryEntry], to url: URL) {
        do {
            try AppSupport.ensureDirectoryExists()
            let data = try JSONEncoder().encode(entries)
            try AppSupport.writePrivate(data, to: url)
        } catch {
            Log.persistence.error("QueryHistoryStore.flush failed: \(error.localizedDescription, privacy: .public)")
        }
    }

    private func load() {
        guard let data = try? Data(contentsOf: url),
              let decoded = try? JSONDecoder().decode([QueryHistoryEntry].self, from: data)
        else { return }
        // Scrub history written by builds that stored secrets verbatim.
        let scrubbed = decoded.map { e in
            QueryHistoryEntry(id: e.id, connectionID: e.connectionID, sql: QueryHistoryRedactor.redact(e.sql),
                              startedAt: e.startedAt, elapsedSec: e.elapsedSec, success: e.success,
                              errorMessage: e.errorMessage.map(QueryHistoryRedactor.redact),
                              rowsAffected: e.rowsAffected)
        }
        entries = scrubbed
        if scrubbed != decoded { scheduleSave() }
    }
}
