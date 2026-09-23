import Foundation
import Observation
import os

/// Recently opened + pinned relations, per (connection, database). Feeds the
/// "Pinned" / "Recent" sidebar sections and ranks recents first in Go to
/// Table. JSON-backed at `AppSupport/navigation.json` with debounced writes,
/// same shape as `WorkspaceStore`.
@MainActor
@Observable
final class NavigationHistoryStore {
    static let shared = NavigationHistoryStore()
    static let recentLimit = 15

    struct Scope: Hashable, Sendable {
        let connectionID: UUID
        let database: String
        var key: String { "\(connectionID.uuidString)|\(database)" }
    }

    struct Record: Codable, Equatable {
        /// Relation ids (`schema.name`), most recent first.
        var recents: [String] = []
        /// Relation ids in the order the user pinned them.
        var pinned: [String] = []
    }

    private(set) var records: [String: Record] = [:]
    @ObservationIgnored private var saveTask: Task<Void, Never>?
    @ObservationIgnored private let url: URL

    private init() {
        self.url = AppSupport.directory.appendingPathComponent("navigation.json")
        load()
    }

    #if DEBUG
    init(testURL: URL) {
        self.url = testURL
        load()
    }
    func flushNowForTests() { flush() }
    #endif

    func record(for scope: Scope) -> Record { records[scope.key] ?? Record() }
    func recents(for scope: Scope) -> [String] { record(for: scope).recents }
    func pinned(for scope: Scope) -> [String] { record(for: scope).pinned }
    func isPinned(_ tableID: String, scope: Scope) -> Bool { pinned(for: scope).contains(tableID) }

    func recordOpen(_ tableID: String, scope: Scope) {
        var r = record(for: scope)
        if r.recents.first == tableID { return }
        r.recents.removeAll { $0 == tableID }
        r.recents.insert(tableID, at: 0)
        if r.recents.count > Self.recentLimit { r.recents.removeLast(r.recents.count - Self.recentLimit) }
        records[scope.key] = r
        scheduleSave()
    }

    func setPinned(_ pinned: Bool, tableID: String, scope: Scope) {
        var r = record(for: scope)
        let already = r.pinned.contains(tableID)
        guard pinned != already else { return }
        if pinned { r.pinned.append(tableID) } else { r.pinned.removeAll { $0 == tableID } }
        records[scope.key] = r
        scheduleSave()
    }

    func togglePinned(_ tableID: String, scope: Scope) {
        setPinned(!isPinned(tableID, scope: scope), tableID: tableID, scope: scope)
    }

    func clearRecents(scope: Scope) {
        var r = record(for: scope)
        guard !r.recents.isEmpty else { return }
        r.recents = []
        records[scope.key] = r
        scheduleSave()
    }

    // MARK: - Persistence

    private func scheduleSave() {
        saveTask?.cancel()
        saveTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 500_000_000)
            if Task.isCancelled { return }
            self?.flush()
        }
    }

    private func flush() {
        do {
            try AppSupport.ensureDirectoryExists()
            let data = try JSONEncoder().encode(records)
            try data.write(to: url, options: .atomic)
        } catch {
            os.Logger(subsystem: "cloud.souris.pgbrain", category: "navigation")
                .error("navigation history save failed: \(error.localizedDescription, privacy: .public)")
        }
    }

    private func load() {
        guard let data = try? Data(contentsOf: url),
              let decoded = try? JSONDecoder().decode([String: Record].self, from: data)
        else { return }
        records = decoded
    }
}
