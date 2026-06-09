import XCTest
import AppKit
@testable import pgBrain

/// Regression guard for the "⌘C in the cell popup copies the whole row"
/// bug. The cell editor is a semitransient `NSPopover`, so the parent
/// table window stays key and `EditableTableView.performKeyEquivalent`
/// would grab ⌘C and run the row-copy provider unless it stands down
/// while an editor is open. Driving `performKeyEquivalent` directly
/// catches the regression without an XCUITest target.
@MainActor
final class DataGridKeyEquivalentTests: XCTestCase {
    override func tearDown() {
        CellEditorPopover._setPresentingForTesting(false)
        super.tearDown()
    }

    private func cmdC() -> NSEvent {
        NSEvent.keyEvent(
            with: .keyDown,
            location: .zero,
            modifierFlags: .command,
            timestamp: 0,
            windowNumber: 0,
            context: nil,
            characters: "c",
            charactersIgnoringModifiers: "c",
            isARepeat: false,
            keyCode: 8
        )!
    }

    func testCommandCCopiesRowWhenNoEditorOpen() {
        let table = EditableTableView()
        var copyCalls = 0
        table.tsvCopyProvider = { copyCalls += 1; return "a\tb" }
        CellEditorPopover._setPresentingForTesting(false)

        let handled = table.performKeyEquivalent(with: cmdC())

        XCTAssertTrue(handled, "grid should handle ⌘C when no editor is open")
        XCTAssertEqual(copyCalls, 1, "row-copy provider should fire")
    }

    func testCommandCStandsDownWhileCellEditorOpen() {
        let table = EditableTableView()
        var copyCalls = 0
        table.tsvCopyProvider = { copyCalls += 1; return "a\tb" }
        CellEditorPopover._setPresentingForTesting(true)

        _ = table.performKeyEquivalent(with: cmdC())

        XCTAssertEqual(copyCalls, 0,
                       "grid must not run row-copy while a cell editor owns ⌘C")
    }
}
