import AppKit
import SwiftUI

@MainActor
enum HelpWindowFactory {
    static func make(onClose: @escaping @MainActor () -> Void) -> NSWindow {
        let hosting = NSHostingController(rootView: HelpView())
        let window = NSWindow(contentViewController: hosting)
        window.title = "pgBrain Help"
        window.styleMask = [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView]
        window.titlebarAppearsTransparent = true
        window.isReleasedWhenClosed = false
        window.setContentSize(NSSize(width: 880, height: 600))
        window.identifier = NSUserInterfaceItemIdentifier("pgBrain.Help")

        let observer = WindowCloseObserver(onClose: onClose)
        window.delegate = observer
        objc_setAssociatedObject(window, &WindowCloseObserver.assocKey, observer, .OBJC_ASSOCIATION_RETAIN)
        return window
    }
}
