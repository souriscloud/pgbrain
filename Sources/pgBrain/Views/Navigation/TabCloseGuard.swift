import AppKit

/// Confirms closing tabs that hold unapplied grid edits. Applying edits
/// lives inside the table tab (its Apply button runs the UPDATE batch), so
/// from the strip or the window chrome the honest choices are Discard or
/// Cancel.
@MainActor
enum TabCloseGuard {
    /// Close `ids` in `workspace`, asking first when any of them is dirty.
    static func close(_ ids: [UUID], in workspace: WorkspaceState, window: NSWindow? = NSApp.keyWindow) {
        let dirty = workspace.dirtyTabs(among: ids)
        guard !dirty.isEmpty else {
            workspace.closeTabs(ids)
            return
        }
        confirmDiscard(dirty.map { workspace.displayTitle(for: $0) }, window: window) { discard in
            if discard { workspace.closeTabs(ids) }
        }
    }

    /// Sheet (or app-modal when there's no usable window) asking to discard
    /// edits in `titles`. `completion(true)` means the user chose Discard.
    static func confirmDiscard(_ titles: [String], window: NSWindow?,
                               completion: @escaping @MainActor (Bool) -> Void) {
        let alert = NSAlert()
        alert.alertStyle = .warning
        if titles.count == 1 {
            alert.messageText = "Discard unapplied changes in “\(titles[0])”?"
        } else {
            alert.messageText = "Discard unapplied changes in \(titles.count) tabs?"
        }
        let list = titles.prefix(8).map { "• \($0)" }.joined(separator: "\n")
        let more = titles.count > 8 ? "\n…and \(titles.count - 8) more" : ""
        alert.informativeText = (titles.count > 1 ? list + more + "\n\n" : "")
            + "These edits haven't been applied to the database. Use Apply in the table tab to keep them."
        alert.addButton(withTitle: "Cancel")
        let discard = alert.addButton(withTitle: "Discard Changes")
        discard.hasDestructiveAction = true
        if let window, window.isVisible, window.attachedSheet == nil {
            alert.beginSheetModal(for: window) { response in
                MainActor.assumeIsolated { completion(response == .alertSecondButtonReturn) }
            }
        } else {
            completion(alert.runModal() == .alertSecondButtonReturn)
        }
    }
}
