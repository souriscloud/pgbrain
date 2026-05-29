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
        window.titleVisibility = .visible
        window.setContentSize(CGSize(width: 1100, height: 720))
        window.minSize = CGSize(width: 720, height: 480)
        window.isReleasedWhenClosed = false
        window.identifier = NSUserInterfaceItemIdentifier("pgBrain.Connection.\(connection.id.uuidString)")

        if connection.isProduction {
            window.appearance = NSAppearance(named: .darkAqua) ?? window.appearance
            window.backgroundColor = NSColor(Tokens.Brand.danger).withAlphaComponent(0.06)
        }

        // Colored band across the title bar so the window header itself
        // carries the connection's identity — red for production, the tag
        // colour otherwise. This is what makes a background window instantly
        // identifiable (and a prod window impossible to mistake).
        let bandColor: NSColor? = connection.isProduction
            ? NSColor(Tokens.Brand.danger)
            : (connection.colorTag == .none ? nil : NSColor(connection.colorTag.swiftUIColor))
        if let bandColor {
            window.addTitlebarAccessoryViewController(TitlebarBandAccessory(color: bandColor))
        }

        // Live title + subtitle that track connection state and the active
        // tab. The subtitle renders right in the title bar, so the window
        // header updates as you connect and move between tabs.
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
        window.title = service.connection.name
        window.subtitle = subtitleText()
    }

    private func subtitleText() -> String {
        switch service.state {
        case .idle, .connecting:
            return "Connecting…"
        case .error:
            return "Connection failed"
        case .closed:
            return "Disconnected"
        case .connected:
            let conn = service.connection
            let db = conn.database.isEmpty ? conn.host : conn.database
            let prefix = conn.isProduction ? "PRODUCTION · " : ""
            if let tab = service.workspace.selectedTab {
                return "\(prefix)\(db) · \(tab.title)"
            }
            return "\(prefix)\(db)"
        }
    }
}

/// A thin full-width colour band pinned to the bottom of the title bar.
/// The accessory's height is the view's height, so it MUST be pinned with an
/// explicit constraint — a frame-only height gets stretched to fill the
/// titlebar's accessory band (which is what made it a fat red block).
final class TitlebarBandAccessory: NSTitlebarAccessoryViewController {
    private static let bandHeight: CGFloat = 3

    init(color: NSColor) {
        super.init(nibName: nil, bundle: nil)
        let band = NSView()
        band.wantsLayer = true
        band.layer?.backgroundColor = color.cgColor
        band.translatesAutoresizingMaskIntoConstraints = false
        view = band
        NSLayoutConstraint.activate([
            band.heightAnchor.constraint(equalToConstant: Self.bandHeight),
        ])
        layoutAttribute = .bottom
        fullScreenMinHeight = Self.bandHeight
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
}
