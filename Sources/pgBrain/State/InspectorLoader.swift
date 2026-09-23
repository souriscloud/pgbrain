import Foundation
import Observation

/// Mirrors `RowsLoader.State` but for `TableInspector.Snapshot`. Backed
/// by `@Observable` so SwiftUI re-renders when the async fetch resolves.
@MainActor
@Observable
final class InspectorLoader {
    enum State: Equatable {
        case idle, loading
        case loaded(TableInspector.Snapshot, ddl: String)
        case error(String)

        static func == (lhs: State, rhs: State) -> Bool {
            switch (lhs, rhs) {
            case (.idle, .idle), (.loading, .loading): true
            case (.loaded, .loaded), (.error, .error):  true
            default: false
            }
        }
    }

    private let table: TableNode
    private let service: ConnectionService
    var state: State = .idle

    init(table: TableNode, service: ConnectionService) {
        self.table = table
        self.service = service
    }

    func load() async {
        guard let client = service.client else {
            state = .error("Not connected")
            return
        }
        state = .loading
        do {
            let snap = try await TableInspector.fetch(client: client, schema: table.schema, table: table.name)
            let ddl = try await TableInspector.renderDDL(client: client, snapshot: snap)
            state = .loaded(snap, ddl: ddl)
        } catch {
            state = .error(PostgresErrorMessage.describe(error))
        }
    }
}
