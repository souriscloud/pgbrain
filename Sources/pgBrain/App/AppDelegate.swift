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

        showWelcome(focus: true)
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

    /// Open a window for `connection` (or focus the existing one).
    func openConnection(_ connection: Connection) {
        if let existing = windowManager.window(for: connection.id) {
            NSApp.activate(ignoringOtherApps: true)
            existing.makeKeyAndOrderFront(nil)
            return
        }

        let result = ConnectionWindowFactory.make(connection: connection) { [weak self] closed in
            guard let self else { return }
            self.windowManager.unregister(window: closed)
            // If no connection windows remain, re-show the Welcome window
            // (matches "no window opened → show welcome screen again").
            if self.windowManager.connectionWindows.isEmpty {
                self.showWelcome(focus: true)
            }
        }
        windowManager.register(window: result.window, service: result.service)

        NSApp.activate(ignoringOtherApps: true)
        result.window.center()
        result.window.makeKeyAndOrderFront(nil)

        // Optional: dismiss the welcome window once a connection is open.
        welcomeWindow?.orderOut(nil)
    }
}
