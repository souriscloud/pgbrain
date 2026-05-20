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
        // Keep the app alive via the menu bar item even with no windows open.
        false
    }

    // MARK: - Window orchestration

    func showWelcome(focus: Bool) {
        if welcomeWindow == nil {
            welcomeWindow = WelcomeWindowFactory.make { [weak self] in
                self?.welcomeWindow = nil
                if let self, self.windowManager.connectionWindows.isEmpty {
                    // No connection windows + welcome closed — hide dock until user reopens.
                    // We don't quit because menu bar item is still available.
                }
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
        if let connection = windowManager.connectionWindows.first {
            NSApp.activate(ignoringOtherApps: true)
            connection.makeKeyAndOrderFront(nil)
        } else {
            showWelcome(focus: true)
        }
    }
}
