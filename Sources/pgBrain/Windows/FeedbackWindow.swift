import AppKit
import SwiftUI

@MainActor
enum FeedbackWindowFactory {
    static func make(onClose: @escaping @MainActor () -> Void) -> NSWindow {
        // The hosting controller owns the close callback so "Cancel" / submit
        // can dismiss the window from inside SwiftUI.
        var window: NSWindow!
        let view = FeedbackView(onClose: { window.performClose(nil) })
        let hosting = NSHostingController(rootView: view)
        window = NSWindow(contentViewController: hosting)
        window.title = "Send Feedback"
        window.styleMask = [.titled, .closable, .fullSizeContentView]
        window.titlebarAppearsTransparent = true
        window.titleVisibility = .hidden
        window.isMovableByWindowBackground = true
        window.isReleasedWhenClosed = false
        window.identifier = NSUserInterfaceItemIdentifier("pgBrain.Feedback")

        let observer = WindowCloseObserver(onClose: onClose)
        window.delegate = observer
        objc_setAssociatedObject(window, &WindowCloseObserver.assocKey, observer, .OBJC_ASSOCIATION_RETAIN)
        return window
    }
}
