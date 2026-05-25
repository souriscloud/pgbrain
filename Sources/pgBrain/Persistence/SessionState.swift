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
    }

    struct Tab: Codable {
        enum Kind: String, Codable { case table, scratchpad }
        var kind: Kind
        /// For `.table` — `schema.name` identifying the source table.
        var tableSchema: String?
        var tableName: String?
        /// For `.scratchpad` — title + buffer text. Sensitive (the user's
        /// drafted SQL) but acceptable given it's in the user's own
        /// Application Support directory.
        var scratchpadTitle: String?
        var scratchpadText: String?
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
    private let writeQueue = DispatchQueue(label: "cloud.souris.pgbrain.session", qos: .utility)
    private var debounceItem: DispatchWorkItem?
    private(set) var lastLoaded: SessionState?

    private init() {
        self.url = AppSupport.stateFileURL
    }

    func load() -> SessionState? {
        guard let data = try? Data(contentsOf: url),
              let state = try? JSONDecoder().decode(SessionState.self, from: data)
        else { return nil }
        lastLoaded = state
        return state
    }

    /// Capture the current set of open windows + their tab state from the
    /// shared `AppDelegate.windowManager`. Schedule a debounced write to
    /// `state.json`.
    func scheduleSnapshot(delay: TimeInterval = 0.5) {
        debounceItem?.cancel()
        let item = DispatchWorkItem { [weak self] in
            Task { @MainActor in
                self?.snapshotAndPersist()
            }
        }
        debounceItem = item
        writeQueue.asyncAfter(deadline: .now() + delay, execute: item)
    }

    private func snapshotAndPersist() {
        guard let delegate = AppDelegate.shared else { return }
        var state = SessionState()
        for entry in delegate.windowManager.entries {
            guard let service = entry.service else { continue }
            let frame = entry.window.frame
            let tabs: [SessionState.Tab] = service.workspace.tabs.map { tab in
                switch tab.kind {
                case .table(let t):
                    return SessionState.Tab(
                        kind: .table,
                        tableSchema: t.schema,
                        tableName: t.name
                    )
                case .scratchpad(let pad):
                    return SessionState.Tab(
                        kind: .scratchpad,
                        scratchpadTitle: pad.title,
                        scratchpadText: pad.text
                    )
                }
            }
            let selectedIndex: Int? = {
                guard let id = service.workspace.selectedID else { return nil }
                return service.workspace.tabs.firstIndex(where: { $0.id == id })
            }()
            state.windows.append(
                SessionState.Window(
                    connectionID: service.connection.id,
                    frame: SessionState.CodableRect(frame),
                    tabs: tabs,
                    selectedTabIndex: selectedIndex
                )
            )
        }
        let url = self.url
        let snapshot = state  // immutable copy captured into the closure
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
