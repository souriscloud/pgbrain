import AppKit
import SwiftUI

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    static private(set) weak var shared: AppDelegate?

    let windowManager = WindowManager()
    private var menuBar: MenuBarController?

    private var welcomeWindow: NSWindow?
    private var aboutWindow: NSWindow?

    func applicationDidFinishLaunching(_ notification: Notification) {
        AppDelegate.shared = self

        NSApp.setActivationPolicy(.regular)

        menuBar = MenuBarController(delegate: self)
        menuBar?.install()

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
            // Spin until the schema is loaded or errored; bail on error.
            while case .loading = service.schemaState {
                try? await Task.sleep(nanoseconds: 100_000_000)
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
                    case .scratchpad:
                        let pad = workspace.openScratchpad()
                        if let title = persisted.scratchpadTitle { pad.title = title }
                        if let text = persisted.scratchpadText { pad.text = text }
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
