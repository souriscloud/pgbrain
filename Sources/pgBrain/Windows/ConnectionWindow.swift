import AppKit
import SwiftUI

@MainActor
enum ConnectionWindowFactory {
    struct Result {
        let window: NSWindow
        let service: ConnectionService
    }

    static func make(connection: Connection, onClose: @escaping @MainActor (NSWindow) -> Void) -> Result {
        let service = ConnectionService(connection: connection)
        let content = ConnectionWindowContent(service: service)
        let hosting = NSHostingController(rootView: content)
        let window = NSWindow(contentViewController: hosting)
        window.title = connection.name
        window.styleMask = [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView]
        window.titlebarAppearsTransparent = true
        // The custom chrome bar (in ConnectionWindowContent) IS the title bar —
        // it draws under the transparent titlebar with the traffic lights on
        // top. Hide the native title text so there's no doubling.
        window.titleVisibility = .hidden
        window.setContentSize(CGSize(width: 1100, height: 720))
        window.minSize = CGSize(width: 720, height: 480)
        window.isReleasedWhenClosed = false
        // The app runs its own session restoration; Cocoa's automatic
        // per-window restoration would otherwise re-apply a stale
        // titleVisibility (.visible) over our hidden title, double-drawing
        // the native title on top of the custom chrome bar.
        window.isRestorable = false
        window.identifier = NSUserInterfaceItemIdentifier("pgBrain.Connection.\(connection.id.uuidString)")

        if connection.isProduction {
            window.appearance = NSAppearance(named: .darkAqua) ?? window.appearance
        }

        // Keep `window.title` synced (name — active tab) for the Window menu,
        // Mission Control, and the ⌘` switcher, even though the titlebar text
        // itself is hidden in favour of the custom chrome bar.
        let titleSync = WindowTitleSync(window: window, service: service)
        objc_setAssociatedObject(window, &WindowTitleSync.assocKey, titleSync, .OBJC_ASSOCIATION_RETAIN)

        let observer = ConnectionWindowCloseObserver(window: window, service: service, onClose: onClose)
        window.delegate = observer
        objc_setAssociatedObject(window, &ConnectionWindowCloseObserver.assocKey, observer, .OBJC_ASSOCIATION_RETAIN)

        // Kick off the connect as soon as the window exists.
        service.start()

        return Result(window: window, service: service)
    }
}

final class ConnectionWindowCloseObserver: NSObject, NSWindowDelegate {
    nonisolated(unsafe) static var assocKey: UInt8 = 0
    private weak var window: NSWindow?
    private let service: ConnectionService
    private let onClose: @MainActor (NSWindow) -> Void

    init(window: NSWindow, service: ConnectionService, onClose: @escaping @MainActor (NSWindow) -> Void) {
        self.window = window
        self.service = service
        self.onClose = onClose
    }

    // The native title flips back to visible on a number of AppKit events
    // (dismissing a sheet → the window becomes key again, fullscreen
    // transitions, etc.) which would draw it on top of the custom chrome bar.
    // Re-hide it whenever the window re-takes focus or changes mode.
    private func rehideTitle(_ notification: Notification) {
        (notification.object as? NSWindow)?.titleVisibility = .hidden
    }
    func windowDidBecomeKey(_ notification: Notification) { rehideTitle(notification) }
    func windowDidBecomeMain(_ notification: Notification) { rehideTitle(notification) }
    func windowDidExitFullScreen(_ notification: Notification) { rehideTitle(notification) }
    func windowDidEnterFullScreen(_ notification: Notification) { rehideTitle(notification) }

    func windowWillClose(_ notification: Notification) {
        MainActor.assumeIsolated {
            service.shutdown()
            if let w = window { onClose(w) }
        }
    }
}

/// Drives the window's `title` + `subtitle` from the live `ConnectionService`.
/// Uses `withObservationTracking` so any change to the observed state
/// (connection state, the selected tab, its title) re-applies and re-arms.
@MainActor
final class WindowTitleSync {
    nonisolated(unsafe) static var assocKey: UInt8 = 0
    private weak var window: NSWindow?
    private let service: ConnectionService

    init(window: NSWindow, service: ConnectionService) {
        self.window = window
        self.service = service
        track()
    }

    private func track() {
        withObservationTracking {
            apply()   // the reads inside apply() register as dependencies
        } onChange: { [weak self] in
            Task { @MainActor in self?.track() }
        }
    }

    private func apply() {
        guard let window else { return }
        // Title text is hidden in the titlebar, but still used by the Window
        // menu / Mission Control / window switcher — keep it descriptive.
        if case .connected = service.state, let tab = service.workspace.selectedTab {
            window.title = "\(service.connection.name) — \(tab.title)"
        } else {
            window.title = service.connection.name
        }
        // Assigning `title` flips `titleVisibility` back to `.visible`, which
        // would draw the native title over the custom chrome bar. Re-hide it
        // every time — this is the actual cause of the double-title.
        window.titleVisibility = .hidden
    }
}
