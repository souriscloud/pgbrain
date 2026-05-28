import Foundation
import Observation

/// A named snapshot of a connection's tabs. Save the current set, then
/// switch back to it later — like browser bookmark folders, scoped to
/// a single connection. Per-connection because table references would
/// be meaningless across different databases.
struct SavedWorkspace: Codable, Identifiable, Equatable {
    let id: UUID
    var name: String
    var tabs: [SavedWorkspaceTab]
    var selectedTabIndex: Int?
    var createdAt: Date
}

/// Mirror of `SessionState.Tab` — keeps the fields needed to
/// reconstruct a tab, but lives in its own JSON so workspace files
/// can evolve independently of the on-disk session.
struct SavedWorkspaceTab: Codable, Equatable {
    enum Kind: String, Codable { case table, scratchpad }
    var kind: Kind
    var tableSchema: String?
    var tableName: String?
    var tableWhereClause: String?
    var tableOrderByClause: String?
    var scratchpadTitle: String?
    var scratchpadText: String?
    var scratchpadSearchPath: String?
    var colorTag: String?
    var tabTitle: String?
}

/// Per-connection saved-workspace registry. JSON-backed at
/// `AppSupport/workspaces.json`; debounced writes — every mutation
/// queues a save 0.5s later so a rename flurry doesn't beat the disk.
@MainActor
@Observable
final class WorkspaceStore {
    static let shared = WorkspaceStore()

    private(set) var byConnection: [UUID: [SavedWorkspace]] = [:]
    @ObservationIgnored private var saveTask: Task<Void, Never>?
    @ObservationIgnored private let url: URL

    private init() {
        self.url = AppSupport.directory.appendingPathComponent("workspaces.json")
        load()
    }

    func workspaces(for connID: UUID) -> [SavedWorkspace] {
        (byConnection[connID] ?? []).sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }

    func save(_ workspace: SavedWorkspace, for connID: UUID) {
        var list = byConnection[connID] ?? []
        if let idx = list.firstIndex(where: { $0.id == workspace.id }) {
            list[idx] = workspace
        } else {
            list.append(workspace)
        }
        byConnection[connID] = list
        scheduleSave()
    }

    func delete(id: UUID, for connID: UUID) {
        var list = byConnection[connID] ?? []
        list.removeAll { $0.id == id }
        if list.isEmpty {
            byConnection.removeValue(forKey: connID)
        } else {
            byConnection[connID] = list
        }
        scheduleSave()
    }

    func rename(id: UUID, to newName: String, for connID: UUID) {
        guard var list = byConnection[connID],
              let idx = list.firstIndex(where: { $0.id == id })
        else { return }
        list[idx].name = newName
        byConnection[connID] = list
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
        // Stringify UUID keys for JSON friendliness.
        var encoded: [String: [SavedWorkspace]] = [:]
        for (id, list) in byConnection {
            encoded[id.uuidString] = list
        }
        do {
            try AppSupport.ensureDirectoryExists()
            let data = try JSONEncoder().encode(encoded)
            try data.write(to: url, options: .atomic)
        } catch {
            NSLog("pgBrain: WorkspaceStore.flush failed: \(error)")
        }
    }

    private func load() {
        guard let data = try? Data(contentsOf: url),
              let decoded = try? JSONDecoder().decode([String: [SavedWorkspace]].self, from: data)
        else { return }
        var out: [UUID: [SavedWorkspace]] = [:]
        for (idStr, list) in decoded {
            if let id = UUID(uuidString: idStr) { out[id] = list }
        }
        self.byConnection = out
    }
}
