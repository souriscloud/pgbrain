import AppKit

/// Confirms closing tabs that hold unapplied grid edits or an open
/// scratchpad transaction. Applying edits lives inside the table tab (its
/// Apply button runs the UPDATE batch), so from the strip or the window
/// chrome the honest choices are Discard or Cancel.
///
/// Order matters: the discard prompt comes first because it has no side
/// effects — cancelling it leaves everything untouched. Only then are
/// transactions resolved, since Commit / Roll Back can't be undone.
/// Tab close, window close and quit all go through here.
@MainActor
enum TabCloseGuard {
    /// The two questions, injectable so the ordering is unit-tested.
    struct Prompts {
        /// Titles of tabs with unapplied edits → true = Discard.
        var discard: @MainActor ([String]) -> Bool
        /// A scratchpad with an open transaction → true = may close (it
        /// committed or rolled back). Only asked for pads with `transaction.isOpen`.
        var transaction: @MainActor (Notebook) -> Bool

        static var live: Prompts {
            Prompts(
                discard: { TabCloseGuard.confirmDiscard($0) },
                transaction: { $0.confirmCloseWithOpenTransaction() }
            )
        }
    }

    /// Close `ids` in `workspace`, asking first when any of them is dirty or
    /// holds an open transaction.
    static func close(_ ids: [UUID], in workspace: WorkspaceState) {
        let closable = confirmClosing(ids, in: workspace)
        guard !closable.isEmpty else { return }
        workspace.closeTabs(closable)
    }

    /// Returns the ids that may close. Cancelling the discard prompt returns
    /// nothing; cancelling one transaction prompt keeps just that tab.
    static func confirmClosing(_ ids: [UUID], in workspace: WorkspaceState,
                               prompts: Prompts = .live) -> [UUID] {
        let dirty = workspace.dirtyTabs(among: ids)
        if !dirty.isEmpty, !prompts.discard(dirty.map { workspace.displayTitle(for: $0) }) {
            return []
        }
        let set = Set(ids)
        var kept: Set<UUID> = []
        for tab in workspace.tabs where set.contains(tab.id) {
            guard case .scratchpad(let pad) = tab.kind, pad.transaction.isOpen else { continue }
            if !prompts.transaction(pad) { kept.insert(tab.id) }
        }
        let closable = ids.filter { !kept.contains($0) }
        releaseSessions(of: closable, in: workspace)
        return closable
    }

    /// All-or-nothing variant for closing whole windows (one or many, e.g.
    /// on quit): one discard prompt across every workspace, then each open
    /// transaction. False = something was cancelled and nothing may close.
    static func confirmClosingAll(_ workspaces: [WorkspaceState], prompts: Prompts = .live) -> Bool {
        let dirtyTitles = workspaces.flatMap { ws in
            ws.dirtyTabs(among: ws.tabs.map(\.id)).map { ws.displayTitle(for: $0) }
        }
        if !dirtyTitles.isEmpty, !prompts.discard(dirtyTitles) { return false }
        for ws in workspaces {
            for tab in ws.tabs {
                guard case .scratchpad(let pad) = tab.kind, pad.transaction.isOpen else { continue }
                if !prompts.transaction(pad) { return false }
            }
        }
        return true
    }

    private static func releaseSessions(of ids: [UUID], in workspace: WorkspaceState) {
        let set = Set(ids)
        for tab in workspace.tabs where set.contains(tab.id) {
            if case .scratchpad(let pad) = tab.kind { pad.closeSession() }
        }
    }

    /// App-modal alert asking to discard edits in `titles`. Synchronous so
    /// window-close and quit can answer AppKit immediately. True = Discard.
    static func confirmDiscard(_ titles: [String]) -> Bool {
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
        let discard = alert.addButton(withTitle: titles.count > 1 ? "Discard All" : "Discard Changes")
        discard.hasDestructiveAction = true
        return alert.runModal() == .alertSecondButtonReturn
    }
}
