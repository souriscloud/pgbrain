import Foundation
import Observation

/// Per-connection-window tab state. Owns the list of open tabs and the
/// selection. Iter-3 ships table tabs only; scratchpad tabs land in iter-4.
@MainActor
@Observable
final class WorkspaceState {
    enum TabKind: Sendable, Equatable {
        case table(TableNode)
    }

    final class Tab: Identifiable, Equatable {
        let id = UUID()
        var kind: TabKind
        var title: String

        init(kind: TabKind, title: String) {
            self.kind = kind
            self.title = title
        }

        static func == (lhs: Tab, rhs: Tab) -> Bool { lhs.id == rhs.id }
    }

    private(set) var tabs: [Tab] = []
    var selectedID: UUID?

    var selectedTab: Tab? {
        guard let id = selectedID else { return nil }
        return tabs.first(where: { $0.id == id })
    }

    /// Open `table` in a new tab, or focus the existing tab if one already
    /// shows the same `(schema, name)`.
    func openTable(_ table: TableNode) {
        if let existing = tabs.first(where: {
            if case let .table(t) = $0.kind { return t.id == table.id } else { return false }
        }) {
            selectedID = existing.id
            return
        }
        let tab = Tab(kind: .table(table), title: table.qualifiedName)
        tabs.append(tab)
        selectedID = tab.id
    }

    func closeTab(id: UUID) {
        guard let idx = tabs.firstIndex(where: { $0.id == id }) else { return }
        tabs.remove(at: idx)
        if selectedID == id {
            selectedID = tabs.indices.contains(idx) ? tabs[idx].id
                : (tabs.last?.id)
        }
    }

    /// Move the tab identified by `id` to sit immediately before the tab
    /// identified by `target`. No-op if either is missing or they're the same.
    func move(id: UUID, before target: UUID) {
        guard id != target,
              let from = tabs.firstIndex(where: { $0.id == id }),
              let to = tabs.firstIndex(where: { $0.id == target })
        else { return }
        let tab = tabs.remove(at: from)
        let insertAt = from < to ? to - 1 : to
        tabs.insert(tab, at: insertAt)
    }
}
