import AppKit
import XCTest
@testable import pgBrain

/// Arrow-key cell jumping in the notebook editor matches modifiers exactly,
/// and a grid cell edit is dropped if the page reloaded under the popover.
@MainActor
final class F2_KeyHandlingTests: XCTestCase {
    private let down: UInt16 = 125
    private let up: UInt16 = 126
    // Arrow key events always carry these; they must not count as modifiers.
    private let arrowFlags: NSEvent.ModifierFlags = [.numericPad, .function]

    private func jump(_ key: UInt16, _ mods: NSEvent.ModifierFlags, first: Bool = false, last: Bool = false) -> Int? {
        SqlCellNSTextView.cellJump(keyCode: key, modifiers: mods.union(arrowFlags), onFirstLine: first, onLastLine: last)
    }

    func testPlainArrowsJumpOnlyAtTheEdge() {
        XCTAssertEqual(jump(down, [], last: true), 1)
        XCTAssertNil(jump(down, [], last: false))
        XCTAssertEqual(jump(up, [], first: true), -1)
        XCTAssertNil(jump(up, [], first: false))
    }

    func testOptionArrowsJumpAnywhere() {
        XCTAssertEqual(jump(down, .option), 1)
        XCTAssertEqual(jump(up, .option), -1)
    }

    func testOtherModifierCombosKeepTextEditing() {
        XCTAssertNil(jump(down, [.option, .shift], last: true), "⌥⇧↓ selects to paragraph end")
        XCTAssertNil(jump(up, [.option, .shift], first: true))
        XCTAssertNil(jump(down, .shift, last: true), "⇧↓ on the last line extends the selection")
        XCTAssertNil(jump(up, .shift, first: true))
        XCTAssertNil(jump(down, .command, last: true), "⌘↓ goes to the end of the document")
        XCTAssertNil(jump(down, [.command, .option], last: true))
        XCTAssertNil(jump(down, .control, last: true))
    }

    func testNonVerticalKeysNeverJump() {
        XCTAssertNil(jump(123, [], first: true, last: true))
        XCTAssertNil(jump(124, .option, first: true, last: true))
    }

    func testEditorCommitRequiresSamePageGeneration() {
        XCTAssertTrue(DataGridView.Coordinator.editorCommitIsCurrent(opened: 3, now: 3))
        XCTAssertFalse(DataGridView.Coordinator.editorCommitIsCurrent(opened: 3, now: 4))
        XCTAssertTrue(DataGridView.Coordinator.editorCommitIsCurrent(opened: nil, now: nil))
        XCTAssertFalse(DataGridView.Coordinator.editorCommitIsCurrent(opened: nil, now: 1))
    }
}
