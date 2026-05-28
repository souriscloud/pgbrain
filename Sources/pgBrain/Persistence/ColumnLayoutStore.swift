import Foundation
import Observation

/// Per-table column-width memory. Keyed by
/// `"<connectionUUID>|<schema>.<table>" → "<columnName>" → CGFloat`.
/// Persisted to `AppSupport/column_layout.json` with a debounce so
/// dragging a column edge doesn't write 100 times per second.
@MainActor
@Observable
final class ColumnLayoutStore {
    static let shared = ColumnLayoutStore()

    private(set) var widths: [String: [String: CGFloat]] = [:]
    @ObservationIgnored private var saveTask: Task<Void, Never>?
    @ObservationIgnored private let url: URL

    private init() {
        self.url = AppSupport.directory.appendingPathComponent("column_layout.json")
        load()
    }

    func width(connectionID: UUID, schema: String, table: String, column: String) -> CGFloat? {
        widths[key(connectionID, schema, table)]?[column]
    }

    func setWidth(_ width: CGFloat, connectionID: UUID, schema: String, table: String, column: String) {
        let k = key(connectionID, schema, table)
        widths[k, default: [:]][column] = width
        scheduleSave()
    }

    private func key(_ id: UUID, _ schema: String, _ table: String) -> String {
        "\(id.uuidString)|\(schema).\(table)"
    }

    private func scheduleSave() {
        saveTask?.cancel()
        saveTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 700_000_000)
            if Task.isCancelled { return }
            self?.flush()
        }
    }

    private func flush() {
        // Encode CGFloat dictionaries via JSONEncoder.
        do {
            try AppSupport.ensureDirectoryExists()
            let data = try JSONEncoder().encode(widths)
            try data.write(to: url, options: .atomic)
        } catch {
            NSLog("pgBrain: ColumnLayoutStore.flush failed: \(error)")
        }
    }

    private func load() {
        guard let data = try? Data(contentsOf: url),
              let decoded = try? JSONDecoder().decode([String: [String: CGFloat]].self, from: data)
        else { return }
        self.widths = decoded
    }
}
