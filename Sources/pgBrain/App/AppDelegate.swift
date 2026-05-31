import AppKit
import SwiftUI

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    static private(set) weak var shared: AppDelegate?

    let windowManager = WindowManager()
    private var menuBar: MenuBarController?

    private var welcomeWindow: NSWindow?
    private var aboutWindow: NSWindow?
    private var feedbackWindow: NSWindow?
    private var helpWindow: NSWindow?

    func applicationDidFinishLaunching(_ notification: Notification) {
        AppDelegate.shared = self

        NSApp.setActivationPolicy(.regular)

        menuBar = MenuBarController(delegate: self)
        menuBar?.install()

        // Boot Sparkle so the SPUUpdater can do its scheduled background
        // check. The first reference initialises the singleton; the menu
        // bar's "Check for Updates…" routes through the same instance.
        _ = UpdateController.shared

        let restored = AppSettings.shared.restoreLastSession
            ? restoreSession()
            : false
        if !restored {
            showWelcome(focus: true)
        }
    }

    /// Reopen every connection window that was open at last save, restoring
    /// frame, tabs, and scratchpad contents. Returns false (caller should
    /// show Welcome) if no session was restorable.
    @discardableResult
    private func restoreSession() -> Bool {
        guard let state = SessionStateStore.shared.load(), !state.windows.isEmpty else { return false }
        var opened = 0
        for snapshot in state.windows {
            guard let conn = ConnectionStore.shared.connections.first(where: { $0.id == snapshot.connectionID }) else { continue }
            openConnection(conn, restoring: snapshot)
            opened += 1
        }
        return opened > 0
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        if !flag && windowManager.connectionWindows.isEmpty {
            showWelcome(focus: true)
        }
        return true
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        false
    }

    // MARK: - Welcome / About

    func showWelcome(focus: Bool) {
        if welcomeWindow == nil {
            welcomeWindow = WelcomeWindowFactory.make { [weak self] in
                self?.welcomeWindow = nil
            }
        }
        if focus {
            NSApp.activate(ignoringOtherApps: true)
            welcomeWindow?.makeKeyAndOrderFront(nil)
            welcomeWindow?.center()
        }
    }

    func showAbout() {
        if aboutWindow == nil {
            aboutWindow = AboutWindowFactory.make { [weak self] in
                self?.aboutWindow = nil
            }
        }
        NSApp.activate(ignoringOtherApps: true)
        aboutWindow?.makeKeyAndOrderFront(nil)
        aboutWindow?.center()
    }

    func showFeedback() {
        if feedbackWindow == nil {
            feedbackWindow = FeedbackWindowFactory.make { [weak self] in
                self?.feedbackWindow = nil
            }
        }
        NSApp.activate(ignoringOtherApps: true)
        feedbackWindow?.makeKeyAndOrderFront(nil)
        feedbackWindow?.center()
    }

    func showHelp() {
        if helpWindow == nil {
            helpWindow = HelpWindowFactory.make { [weak self] in
                self?.helpWindow = nil
            }
        }
        NSApp.activate(ignoringOtherApps: true)
        helpWindow?.makeKeyAndOrderFront(nil)
        helpWindow?.center()
    }

    /// Bring the nth open connection window forward. `index` is
    /// 0-based; out-of-range is a no-op. Powers the per-window
    /// ⌃1..⌃9 shortcuts that switch between connections without
    /// having to mouse over to the menu bar.
    func focusConnectionWindow(at index: Int) {
        let entries = windowManager.entries
        guard entries.indices.contains(index) else { return }
        NSApp.activate(ignoringOtherApps: true)
        entries[index].window.makeKeyAndOrderFront(nil)
    }

    func bringAnyWindowToFront() {
        if let entry = windowManager.connectionWindows.first {
            NSApp.activate(ignoringOtherApps: true)
            entry.window.makeKeyAndOrderFront(nil)
        } else {
            showWelcome(focus: true)
        }
    }

    // MARK: - Connection windows

    /// Open a window for `connection` (or focus the existing one). Pass
    /// `restoring` to repopulate the window's frame + tab list + scratchpad
    /// text from a `SessionState` snapshot.
    func openConnection(_ connection: Connection, restoring snapshot: SessionState.Window? = nil) {
        if let existing = windowManager.window(for: connection.id) {
            NSApp.activate(ignoringOtherApps: true)
            existing.makeKeyAndOrderFront(nil)
            return
        }

        let result = ConnectionWindowFactory.make(connection: connection) { [weak self] closed in
            guard let self else { return }
            self.windowManager.unregister(window: closed)
            SessionStateStore.shared.scheduleSnapshot()
            if self.windowManager.connectionWindows.isEmpty {
                self.showWelcome(focus: true)
            }
        }
        windowManager.register(window: result.window, service: result.service)

        if let snapshot {
            result.window.setFrame(snapshot.frame.ns, display: true)
            // Defer tab restoration until the schema loads so tables can be
            // resolved to live TableNode instances.
            restoreTabs(into: result.service, from: snapshot)
        } else {
            result.window.center()
        }

        NSApp.activate(ignoringOtherApps: true)
        result.window.makeKeyAndOrderFront(nil)
        SessionStateStore.shared.scheduleSnapshot()

        welcomeWindow?.orderOut(nil)
    }

    /// Wait for the connection's schema to load, then replay each persisted
    /// tab against the live schema. Tables that no longer exist are dropped.
    private func restoreTabs(into service: ConnectionService, from snapshot: SessionState.Window) {
        Task { @MainActor in
            // Spin until the schema reaches a terminal state. The earlier
            // version only waited on `.loading`, but a fresh window starts
            // at `.idle` and may stay there for a beat before connect kicks
            // off — `case .idle` would fall through the wait and the
            // subsequent `case .loaded` check would fail, leaving tabs
            // unrestored. Loop while idle OR loading; exit on loaded/error.
            // Hard cap at ~30s so a hung connect can't park this Task
            // forever.
            let deadline = Date().addingTimeInterval(30)
            while Date() < deadline {
                switch service.schemaState {
                case .loaded, .error:
                    break
                case .idle, .loading:
                    try? await Task.sleep(nanoseconds: 100_000_000)
                    continue
                }
                break
            }
            if case .loaded = service.schemaState {
                let workspace = service.workspace
                for (idx, persisted) in snapshot.tabs.enumerated() {
                    switch persisted.kind {
                    case .table:
                        guard let schema = persisted.tableSchema, let name = persisted.tableName,
                              let live = service.schema.schemas.first(where: { $0.name == schema })?
                                .tables.first(where: { $0.name == name })
                        else { continue }
                        workspace.openTable(live)
                        // Carry the per-tab WHERE + ORDER BY + color +
                        // custom title onto the newly opened Tab so the
                        // table view picks them up on its first appear.
                        if let opened = workspace.tabs.last {
                            opened.tableWhereClause = persisted.tableWhereClause ?? ""
                            opened.tableOrderByClause = persisted.tableOrderByClause ?? ""
                            opened.color = persisted.colorTag.flatMap { Connection.ColorTag(rawValue: $0) }
                            if let custom = persisted.tabTitle { opened.title = custom }
                        }
                    case .scratchpad:
                        let pad = workspace.openScratchpad()
                        if let title = persisted.scratchpadTitle { pad.title = title }
                        if let text = persisted.scratchpadText, !text.isEmpty {
                            pad.sql = text
                        }
                        pad.searchPath = persisted.scratchpadSearchPath
                        if let opened = workspace.tabs.last {
                            opened.color = persisted.colorTag.flatMap { Connection.ColorTag(rawValue: $0) }
                            // openScratchpad() seeded tab.title from
                            // pad.title's default ("Query N"); push the
                            // user's renamed title onto the chip too,
                            // otherwise the strip shows the default
                            // while the underlying Notebook carries the
                            // correct name.
                            if let custom = persisted.tabTitle {
                                opened.title = custom
                            } else if let scratchTitle = persisted.scratchpadTitle {
                                opened.title = scratchTitle
                            }
                        }
                    }
                    if snapshot.selectedTabIndex == idx, let last = workspace.tabs.last {
                        workspace.selectedID = last.id
                    }
                }
                SessionStateStore.shared.scheduleSnapshot()
            }
        }
    }
}
