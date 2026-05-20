import AppKit
import SwiftUI

@MainActor
enum WelcomeWindowFactory {
    static func make(onClose: @escaping @MainActor () -> Void) -> NSWindow {
        let content = WelcomeView()
        let hosting = NSHostingController(rootView: content)
        let window = NSWindow(contentViewController: hosting)
        window.title = "Welcome to pgBrain"
        window.styleMask = [.titled, .closable, .miniaturizable, .fullSizeContentView]
        window.titlebarAppearsTransparent = true
        window.titleVisibility = .hidden
        window.isMovableByWindowBackground = true
        window.setContentSize(Tokens.Window.welcomeSize)
        window.minSize = Tokens.Window.welcomeSize
        window.isReleasedWhenClosed = false
        window.identifier = NSUserInterfaceItemIdentifier("pgBrain.Welcome")

        let observer = WindowCloseObserver(onClose: onClose)
        window.delegate = observer
        objc_setAssociatedObject(window, &WindowCloseObserver.assocKey, observer, .OBJC_ASSOCIATION_RETAIN)

        return window
    }
}

/// Holds a `windowWillClose` callback for an NSWindow without forcing the owner
/// to keep a strong ref. Attached via `objc_setAssociatedObject`.
final class WindowCloseObserver: NSObject, NSWindowDelegate {
    nonisolated(unsafe) static var assocKey: UInt8 = 0
    private let onClose: @MainActor () -> Void
    init(onClose: @escaping @MainActor () -> Void) { self.onClose = onClose }

    func windowWillClose(_ notification: Notification) {
        MainActor.assumeIsolated { onClose() }
    }
}
