import AppKit
import Foundation

/// On-disk session model. Persisted to
/// `~/Library/Application Support/pgBrain/state.json` whenever a tracked
/// state mutation happens (debounced so we don't blow up the disk with
/// keystroke-level writes).
struct SessionState: Codable {
    struct Window: Codable {
        var connectionID: UUID
        /// `NSWindow.frame` flattened so we can restore size + position on
        /// the same display layout.
        var frame: CodableRect
        var tabs: [Tab]
        /// Index of the selected tab in `tabs`. Index-based rather than
        /// UUID-based because UUIDs are regenerated on restore.
        var selectedTabIndex: Int?
        /// Database this window was opened on when it differs per window
        /// (database switcher). nil/empty = the connection's own database.
        var database: String?
        var sidebarVisible: Bool?
        var sidebarFilter: String?
        var sidebarIncludeColumns: Bool?
        /// Stable sidebar node ids that were expanded.
        var expandedSidebarNodes: [String]?
    }

    struct Tab: Codable {
        enum Kind: String, Codable { case table, scratchpad }
        var kind: Kind
        /// For `.table` — `schema.name` identifying the source table.
        var tableSchema: String?
        var tableName: String?
        /// Raw `WHERE` body for `.table` tabs (no leading keyword).
        var tableWhereClause: String?
        /// Raw `ORDER BY` body for `.table` tabs.
        var tableOrderByClause: String?
        /// For `.scratchpad` — title + buffer text. Sensitive (the user's
        /// drafted SQL) but acceptable given it's in the user's own
        /// Application Support directory.
        var scratchpadTitle: String?
        var scratchpadText: String?
        /// Per-scratchpad `search_path` override. Nil = use the
        /// connection's default. Optional so existing on-disk state
        /// without this field decodes cleanly.
        var scratchpadSearchPath: String?
        /// Tab color tag (any tab kind). Optional so older snapshots
        /// still decode cleanly.
        var colorTag: String?
        /// User-renamed tab title (any tab kind). For scratchpads we
        /// also keep `scratchpadTitle` in sync because the saved-
        /// queries panel reads it from the Notebook directly.
        var tabTitle: String?
        var isPreview: Bool?
        var isPinned: Bool?
        /// `.table` tabs: Data / Structure / DDL, and grid / form / map.
        /// Nil = the defaults (Data, grid).
        var tablePane: String?
        var tableRowViewMode: String?
    }

    struct CodableRect: Codable {
        var x: CGFloat
        var y: CGFloat
        var w: CGFloat
        var h: CGFloat

        init(_ rect: NSRect) {
            x = rect.origin.x
            y = rect.origin.y
            w = rect.size.width
            h = rect.size.height
        }
        var ns: NSRect { NSRect(x: x, y: y, width: w, height: h) }
    }

    var version: Int = 1
    var savedAt: Date = Date()
    var windows: [Window] = []
}

/// Read/write the on-disk session file. Loading is best-effort — a missing
/// or corrupt file just yields a fresh blank session. Writing is debounced
/// behind a serial dispatch queue so a flurry of mutations only triggers
/// one I/O round-trip.
@MainActor
final class SessionStateStore {
    static let shared = SessionStateStore()

    private let url: URL
    /// Disk-write queue. Used only inside `snapshotAndPersist` for the
    /// actual JSON file write — the *debounce* is now a Task that stays on
    /// the main actor so Swift 6's isolation runtime check doesn't fire
    /// when crossing back from a non-main DispatchQueue into a `@MainActor`
    /// closure (that would trap as
    /// `dispatch_assert_queue` from `_swift_task_checkIsolatedSwift`).
    private let writeQueue = DispatchQueue(label: "cloud.souris.pgbrain.session", qos: .utility)
    private var debounceTask: Task<Void, Never>?
    private(set) var lastLoaded: SessionState?

    private init() {
        self.url = AppSupport.stateFileURL
        AppTermination.register("SessionStateStore") { [weak self] in self?.flushNow() }
    }

    /// Write a pending debounced snapshot synchronously. Only when one is
    /// pending: quitting mid-restore must not overwrite the saved session
    /// with half-restored windows.
    func flushNow() {
        guard let task = debounceTask, !task.isCancelled else { return }
        task.cancel()
        debounceTask = nil
        snapshotAndPersist()
        writeQueue.sync {}
    }

    func load() -> SessionState? {
        guard let data = try? Data(contentsOf: url),
              let state = try? JSONDecoder().decode(SessionState.self, from: data)
        else { return nil }
        lastLoaded = state
        return state
    }

    /// Capture the current set of open windows + their tab state from the
    /// shared `AppDelegate.windowManager`. Debounces via a single Task —
    /// repeat calls within `delay` cancel the previous one. The actual
    /// disk write is hopped to `writeQueue` from inside
    /// `snapshotAndPersist`.
    func scheduleSnapshot(delay: TimeInterval = 0.5) {
        debounceTask?.cancel()
        debounceTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
            if Task.isCancelled { return }
            self?.debounceTask = nil
            self?.snapshotAndPersist()
        }
    }

    /// One open window's worth of input to the snapshot builder. Carries
    /// only the primitives `makeSnapshot` needs so the builder has no
    /// `AppDelegate`/`NSWindow` dependency and stays unit-testable.
    struct WindowInput {
        let connectionID: UUID
        let frame: NSRect
        let workspace: WorkspaceState
        var database: String = ""
    }

    /// Pure builder: flatten a set of open windows into the on-disk
    /// `SessionState`. Extracted from `snapshotAndPersist` so the
    /// tab-flattening — historically the crashiest path in the app — is
    /// exercised by `swift test` without a live `AppDelegate` or window.
    static func makeSnapshot(windows: [WindowInput]) -> SessionState {
        var state = SessionState()
        for win in windows {
            let tabs: [SessionState.Tab] = win.workspace.tabs.map { tab in
                switch tab.kind {
                case .table(let t):
                    return SessionState.Tab(
                        kind: .table,
                        tableSchema: t.schema,
                        tableName: t.name,
                        tableWhereClause: tab.tableWhereClause.isEmpty ? nil : tab.tableWhereClause,
                        tableOrderByClause: tab.tableOrderByClause.isEmpty ? nil : tab.tableOrderByClause,
                        colorTag: tab.color?.rawValue,
                        tabTitle: tab.title == t.qualifiedName ? nil : tab.title,
                        isPreview: tab.isPreview ? true : nil,
                        isPinned: tab.isPinned ? true : nil,
                        tablePane: tab.tableViewState.pane == .data ? nil : tab.tableViewState.pane.rawValue,
                        tableRowViewMode: tab.tableViewState.rowViewMode == .grid
                            ? nil : tab.tableViewState.rowViewMode.rawValue
                    )
                case .scratchpad(let pad):
                    return SessionState.Tab(
                        kind: .scratchpad,
                        scratchpadTitle: pad.title,
                        scratchpadText: pad.plainText,
                        scratchpadSearchPath: pad.searchPath,
                        colorTag: tab.color?.rawValue,
                        tabTitle: tab.title == pad.title ? nil : tab.title,
                        isPinned: tab.isPinned ? true : nil
                    )
                }
            }
            let selectedIndex: Int? = {
                guard let id = win.workspace.selectedID else { return nil }
                return win.workspace.tabs.firstIndex(where: { $0.id == id })
            }()
            state.windows.append(
                SessionState.Window(
                    connectionID: win.connectionID,
                    frame: SessionState.CodableRect(win.frame),
                    tabs: tabs,
                    selectedTabIndex: selectedIndex,
                    database: win.database.isEmpty ? nil : win.database,
                    sidebarVisible: win.workspace.sidebarVisible,
                    sidebarFilter: win.workspace.sidebarFilter.isEmpty ? nil : win.workspace.sidebarFilter,
                    sidebarIncludeColumns: win.workspace.sidebarIncludeColumns ? true : nil,
                    expandedSidebarNodes: win.workspace.expandedSidebarNodes.map { Array($0).sorted() }
                )
            )
        }
        return state
    }

    private func snapshotAndPersist() {
        guard let delegate = AppDelegate.shared else { return }
        let windows: [WindowInput] = delegate.windowManager.entries.compactMap { entry in
            guard let service = entry.service else { return nil }
            // Only record an override: a window on the saved database
            // should follow later edits to the connection's database.
            let saved = ConnectionStore.shared.connections.first { $0.id == service.connection.id }?.database
            let override = service.connection.database == saved ? "" : service.connection.database
            return WindowInput(connectionID: service.connection.id,
                               frame: entry.window.frame,
                               workspace: service.workspace,
                               database: override)
        }
        let snapshot = Self.makeSnapshot(windows: windows)
        let url = self.url
        writeQueue.async {
            do {
                let data = try JSONEncoder().encode(snapshot)
                try AppSupport.ensureDirectoryExists()
                try data.write(to: url, options: .atomic)
            } catch {
                // Best-effort — session restore is a convenience.
            }
        }
    }
}
