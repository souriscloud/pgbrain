import AppKit
import SwiftUI

@MainActor
enum ConnectionWindowFactory {
    static func make(connection: Connection, onClose: @escaping @MainActor (NSWindow) -> Void) -> NSWindow {
        let service = ConnectionService(connection: connection)
        let content = ConnectionWindowContent(service: service)
        let hosting = NSHostingController(rootView: content)
        let window = NSWindow(contentViewController: hosting)
        window.title = connection.name
        window.subtitle = "\(connection.username)@\(connection.host):\(connection.port)"
        window.styleMask = [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView]
        window.titlebarAppearsTransparent = true
        window.titleVisibility = .visible
        window.setContentSize(CGSize(width: 1100, height: 720))
        window.minSize = CGSize(width: 720, height: 480)
        window.isReleasedWhenClosed = false
        window.identifier = NSUserInterfaceItemIdentifier("pgBrain.Connection.\(connection.id.uuidString)")

        // Production red title bar accent.
        if connection.isProduction {
            window.appearance = NSAppearance(named: .darkAqua) ?? window.appearance
            window.backgroundColor = NSColor(Tokens.Brand.danger).withAlphaComponent(0.06)
        }

        let observer = ConnectionWindowCloseObserver(window: window, service: service, onClose: onClose)
        window.delegate = observer
        objc_setAssociatedObject(window, &ConnectionWindowCloseObserver.assocKey, observer, .OBJC_ASSOCIATION_RETAIN)

        // Kick off the connect as soon as the window exists.
        service.start()

        return window
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

    func windowWillClose(_ notification: Notification) {
        MainActor.assumeIsolated {
            service.shutdown()
            if let w = window { onClose(w) }
        }
    }
}
