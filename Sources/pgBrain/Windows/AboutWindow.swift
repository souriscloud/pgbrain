import AppKit
import SwiftUI

@MainActor
enum AboutWindowFactory {
    static func make(onClose: @escaping @MainActor () -> Void) -> NSWindow {
        let hosting = NSHostingController(rootView: AboutView())
        let window = NSWindow(contentViewController: hosting)
        window.title = "About pgBrain"
        window.styleMask = [.titled, .closable, .fullSizeContentView]
        window.titlebarAppearsTransparent = true
        window.titleVisibility = .hidden
        window.isMovableByWindowBackground = true
        window.setContentSize(Tokens.Window.aboutSize)
        window.isReleasedWhenClosed = false
        window.identifier = NSUserInterfaceItemIdentifier("pgBrain.About")

        let observer = WindowCloseObserver(onClose: onClose)
        window.delegate = observer
        objc_setAssociatedObject(window, &WindowCloseObserver.assocKey, observer, .OBJC_ASSOCIATION_RETAIN)
        return window
    }
}
