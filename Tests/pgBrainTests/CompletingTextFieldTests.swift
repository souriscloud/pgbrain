import XCTest
import SwiftUI
import AppKit
@testable import pgBrain

/// Regression guard for the WHERE/ORDER-BY strip "second filter doesn't
/// re-apply" bug. The commit must carry the field's *live* string, not a
/// SwiftUI `@State` draft that can lag a keystroke behind on a same-tick
/// Enter. Driving the coordinator's delegate method directly catches the
/// regression without an XCUITest target (runs under `swift test`).
@MainActor
final class CompletingTextFieldTests: XCTestCase {
    func testEndEditingCommitsLiveFieldValue() {
        var draft = "id = 1"
        var committed: String?
        let binding = Binding(get: { draft }, set: { draft = $0 })
        let coord = CompletingTextField.Coordinator(
            text: binding,
            completions: { _ in [] },
            onCommit: { committed = $0 }
        )

        // The field's live value is the newly-typed clause; the binding
        // snapshot still reads the previous one. The commit must report
        // the field, not the lagging binding.
        let field = NSTextField()
        field.stringValue = "id = 2"
        coord.controlTextDidEndEditing(
            Notification(name: NSControl.textDidEndEditingNotification, object: field)
        )

        XCTAssertEqual(committed, "id = 2",
                       "commit must carry the field's live value, not the stale draft")
    }

    func testEndEditingFallsBackToBindingWhenNoField() {
        var draft = "created_at DESC"
        var committed: String?
        let binding = Binding(get: { draft }, set: { draft = $0 })
        let coord = CompletingTextField.Coordinator(
            text: binding,
            completions: { _ in [] },
            onCommit: { committed = $0 }
        )

        coord.controlTextDidEndEditing(
            Notification(name: NSControl.textDidEndEditingNotification, object: nil)
        )

        XCTAssertEqual(committed, "created_at DESC")
    }
}
