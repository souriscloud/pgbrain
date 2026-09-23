import Foundation

/// Decisions for anything that would replace the loaded page while the grid
/// holds staged changes (paging, sorting, filtering, refresh, FK jumps).
/// Pure so the rules are unit-tested; `RowsLoader` and the WHERE strip act
/// on the answers.
enum DirtyGuard {
    enum Decision: Equatable {
        /// Nothing staged — go ahead.
        case proceed
        /// Staged changes would be lost — ask Apply / Discard / Cancel.
        case confirm
        /// An Apply is in flight; its splice-back needs the current page.
        case block
    }

    static func decide(hasPendingChanges: Bool, isApplying: Bool) -> Decision {
        if isApplying { return .block }
        return hasPendingChanges ? .confirm : .proceed
    }

    enum Choice: Equatable { case apply, discard, cancel }

    enum Resolution: Equatable {
        case applyThenProceed
        case discardThenProceed
        case stay
    }

    static func resolve(_ choice: Choice) -> Resolution {
        switch choice {
        case .apply: return .applyThenProceed
        case .discard: return .discardThenProceed
        case .cancel: return .stay
        }
    }

    /// After "Apply" from the prompt: only move on when the apply really
    /// landed and left nothing behind (a failed apply keeps the edits and the
    /// page so the user can fix them).
    static func proceedAfterApply(succeeded: Bool, stillPending: Bool) -> Bool {
        succeeded && !stillPending
    }

    /// How a WHERE / ORDER BY field commit came about. The field reports a
    /// commit on focus loss too; clicking from the strip into the grid must
    /// not become "reload and throw away my edits".
    enum CommitTrigger: Equatable { case enter, focusLoss }

    enum ClauseCommit: Equatable {
        case ignore
        case reload
        case confirmReload
        /// Keep the typed text as an unsubmitted draft; Enter submits it.
        case keepDraft
    }

    static func clauseCommit(trigger: CommitTrigger, changed: Bool, hasPendingChanges: Bool) -> ClauseCommit {
        guard changed else { return .ignore }
        switch (trigger, hasPendingChanges) {
        case (_, false): return .reload
        case (.enter, true): return .confirmReload
        case (.focusLoss, true): return .keepDraft
        }
    }
}
