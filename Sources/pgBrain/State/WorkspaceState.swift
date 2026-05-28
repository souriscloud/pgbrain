import Foundation
import Observation

/// Per-connection-window tab state. Tabs are either a read-only table view
/// (iter-3) or a SQL scratchpad with inline result blocks (iter-4).
@MainActor
@Observable
final class WorkspaceState {
    enum TabKind: Equatable {
        case table(TableNode)
        case scratchpad(Notebook)

        static func == (lhs: TabKind, rhs: TabKind) -> Bool {
            switch (lhs, rhs) {
            case (.table(let l), .table(let r)): return l.id == r.id
            case (.scratchpad(let l), .scratchpad(let r)): return l === r
            default: return false
            }
        }
    }

    /// Which pane of a `.table` tab is currently shown. Free-floating
    /// rather than nested under `TabKind` because the picker is purely a
    /// UI concept — session restore doesn't care which pane was last
    /// active.
    enum TablePane: String, Sendable {
        case data, structure, ddl
    }

    @Observable
    final class Tab: Identifiable, Equatable {
        let id = UUID()
        var kind: TabKind
        var title: String
        /// Cross-view signal: set by sidebar context-menu items
        /// ("Show Structure", "Show CREATE SQL") to nudge an already-open
        /// table tab onto a specific pane. `TableTabView` consumes it on
        /// change and resets to nil so the same value can be sent again.
        var requestedPane: TablePane?
        /// Drives the small dot on the tab chip — only meaningful for
        /// `.table` tabs with a dirty edit buffer right now. Kept on
        /// `Tab` so the strip can render it without reaching into the
        /// per-tab content view.
        var hasPendingChanges: Bool = false
        /// Optional color accent for the tab chip. `nil` = no tint;
        /// otherwise paints the active-tab underline + a soft background
        /// in the picked color. Persisted across session restore.
        var color: Connection.ColorTag?
        /// Pulse signal: set to `true` to ask the tab strip to start an
        /// inline rename on this tab. The chip flips the flag back to
        /// `false` after consuming it so the same nudge can fire again.
        var requestedRename: Bool = false
        /// Pulse signal: set to `true` to ask the host window to pop
        /// a colour-picker dialog for this tab. Same consume-on-use
        /// contract as `requestedRename`.
        var requestedColorPicker: Bool = false
        /// Persisted raw WHERE / ORDER BY clauses for `.table` tabs —
        /// just the bodies, no leading keyword. Empty = no clause.
        /// Survives session restore via `SessionState.Tab`.
        var tableWhereClause: String = ""
        var tableOrderByClause: String = ""

        init(kind: TabKind, title: String) {
            self.kind = kind
            self.title = title
        }

        static func == (lhs: Tab, rhs: Tab) -> Bool { lhs.id == rhs.id }
    }

    private(set) var tabs: [Tab] = []
    var selectedID: UUID?
    @ObservationIgnored private var scratchpadCounter = 0
    /// Fires immediately after a tab is removed. The owning
    /// `ConnectionService` uses this to prune its loader cache, so
    /// closed-tab loaders + edit buffers don't leak.
    @ObservationIgnored var onTabClosed: ((UUID) -> Void)?

    var selectedTab: Tab? {
        guard let id = selectedID else { return nil }
        return tabs.first(where: { $0.id == id })
    }

    /// Open `table` in a new tab, or focus the existing tab if one already
    /// shows the same `(schema, name)`. `focusPane` lets sidebar context
    /// menus route to a non-default pane: an existing tab gets its
    /// `requestedPane` poked (TableTabView watches and switches), a new
    /// tab carries the request along so its first render lands on the
    /// asked-for pane.
    func openTable(_ table: TableNode, focusPane: TablePane = .data) {
        if let existing = tabs.first(where: {
            if case let .table(t) = $0.kind { return t.id == table.id } else { return false }
        }) {
            existing.requestedPane = focusPane
            selectedID = existing.id
            return
        }
        let tab = Tab(kind: .table(table), title: table.qualifiedName)
        tab.requestedPane = focusPane
        tabs.append(tab)
        selectedID = tab.id
        SessionStateStore.shared.scheduleSnapshot()
    }

    /// Always opens a fresh scratchpad — unlike table tabs we don't dedupe,
    /// since users may want multiple independent notebooks side by side.
    @discardableResult
    func openScratchpad() -> Notebook {
        scratchpadCounter += 1
        let pad = Notebook(title: "Query \(scratchpadCounter)")
        let tab = Tab(kind: .scratchpad(pad), title: pad.title)
        tabs.append(tab)
        selectedID = tab.id
        SessionStateStore.shared.scheduleSnapshot()
        return pad
    }

    func closeTab(id: UUID) {
        guard let idx = tabs.firstIndex(where: { $0.id == id }) else { return }
        tabs.remove(at: idx)
        if selectedID == id {
            selectedID = tabs.indices.contains(idx) ? tabs[idx].id
                : (tabs.last?.id)
        }
        onTabClosed?(id)
        SessionStateStore.shared.scheduleSnapshot()
    }

    // MARK: - Keyboard-driven tab navigation

    /// Close whichever tab is currently selected. No-op when the
    /// workspace is empty so callers can fall through to a window
    /// close on ⌘W.
    func closeCurrentTab() {
        guard let id = selectedID else { return }
        closeTab(id: id)
    }

    /// Cycle to the next tab, wrapping at the end. Matches Safari /
    /// Chrome / Cmd+⌥→ behaviour.
    func nextTab() {
        guard !tabs.isEmpty else { return }
        let curr = tabs.firstIndex(where: { $0.id == selectedID }) ?? -1
        let next = (curr + 1) % tabs.count
        selectedID = tabs[next].id
    }

    /// Cycle to the previous tab, wrapping at the start.
    func previousTab() {
        guard !tabs.isEmpty else { return }
        let curr = tabs.firstIndex(where: { $0.id == selectedID }) ?? tabs.count
        let prev = (curr - 1 + tabs.count) % tabs.count
        selectedID = tabs[prev].id
    }

    /// Jump to the nth tab (0-indexed). Out-of-range is a no-op.
    /// `⌘9` traditionally jumps to the LAST tab — callers map that
    /// to `tabs.count - 1` themselves so this stays generic.
    func selectTab(at index: Int) {
        guard index >= 0, index < tabs.count else { return }
        selectedID = tabs[index].id
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
        SessionStateStore.shared.scheduleSnapshot()
    }
}
