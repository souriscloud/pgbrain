import XCTest
import AppKit
@testable import pgBrain

/// The grid claims ⌘C / ⌘V / ⌘A / ⌘Z / ⌘⇧Z / ⌃⌘N only while it is the first
/// responder of the key window. Regression guard for the grid answering ⌘C
/// typed into the WHERE field, the find bar, the SQL editor or a cell-editor
/// popover (its own key window) by copying grid cells.
@MainActor
final class DataGridKeyEquivalentTests: XCTestCase {

    /// Records what the table forwarded.
    private final class Recorder: EditableTableViewHandler {
        var calls: [String] = []
        func gridCopy() -> Bool { calls.append("copy"); return true }
        func gridPaste() -> Bool { calls.append("paste"); return true }
        func gridSelectAll() { calls.append("selectAll") }
        func gridUndo() -> Bool { calls.append("undo"); return true }
        func gridRedo() -> Bool { calls.append("redo"); return true }
        var gridCanUndo: Bool { true }
        var gridCanRedo: Bool { true }
        var gridCanPaste: Bool { true }
        var gridHasSelection: Bool { true }
        func gridSetNull() { calls.append("null") }
        func gridDeleteRows() { calls.append("deleteRows") }
        func gridMove(rowDelta: Int, colDelta: Int, extend: Bool, wrap: Bool) {
            calls.append("move \(rowDelta),\(colDelta)\(extend ? " extend" : "")\(wrap ? " wrap" : "")")
        }
        func gridJump(rowEdge: Int, colEdge: Int, extend: Bool) { calls.append("jump \(rowEdge),\(colEdge)") }
        func gridBeginEditing(seed: String?) { calls.append("edit \(seed ?? "-")") }
        func gridEscape() { calls.append("escape") }
        func gridMouseDown(row: Int, tableColumn: Int, modifiers: NSEvent.ModifierFlags, clickCount: Int) -> Bool { true }
        func gridDrag(toRow row: Int, tableColumn: Int) {}
        func gridContextMenu(row: Int, tableColumn: Int) -> NSMenu? { nil }
        func gridHoverPreview(row: Int, tableColumn: Int) -> String? { nil }
    }

    /// Headless test windows never become key; this one says it is.
    private final class KeyWindow: NSWindow {
        var pretendKey = true
        override var isKeyWindow: Bool { pretendKey }
        override var canBecomeKey: Bool { true }
    }

    private struct Fixture {
        let window: KeyWindow
        let table: EditableTableView
        let field: NSTextField
        let recorder: Recorder
    }

    private func makeFixture() -> Fixture {
        let window = KeyWindow(contentRect: NSRect(x: 0, y: 0, width: 400, height: 300),
                               styleMask: [.titled], backing: .buffered, defer: true)
        window.isReleasedWhenClosed = false
        let content = NSView(frame: window.contentRect(forFrameRect: window.frame))
        let table = EditableTableView(frame: NSRect(x: 0, y: 0, width: 400, height: 200))
        let field = NSTextField(frame: NSRect(x: 0, y: 220, width: 200, height: 22))
        content.addSubview(table)
        content.addSubview(field)
        window.contentView = content
        let recorder = Recorder()
        table.handler = recorder
        return Fixture(window: window, table: table, field: field, recorder: recorder)
    }

    private func key(_ chars: String, _ flags: NSEvent.ModifierFlags, keyCode: UInt16 = 0, window: NSWindow? = nil) -> NSEvent {
        NSEvent.keyEvent(
            with: .keyDown, location: .zero, modifierFlags: flags, timestamp: 0,
            windowNumber: window?.windowNumber ?? 0, context: nil,
            characters: chars, charactersIgnoringModifiers: chars,
            isARepeat: false, keyCode: keyCode
        )!
    }

    func testGridHandlesEquivalentsWhenItIsFirstResponder() {
        let f = makeFixture()
        XCTAssertTrue(f.window.makeFirstResponder(f.table))
        XCTAssertTrue(f.table.ownsKeyboardFocus)

        XCTAssertTrue(f.table.performKeyEquivalent(with: key("c", .command)))
        XCTAssertTrue(f.table.performKeyEquivalent(with: key("v", .command)))
        XCTAssertTrue(f.table.performKeyEquivalent(with: key("a", .command)))
        XCTAssertTrue(f.table.performKeyEquivalent(with: key("z", .command)))
        XCTAssertTrue(f.table.performKeyEquivalent(with: key("z", [.command, .shift])))
        XCTAssertTrue(f.table.performKeyEquivalent(with: key("n", [.command, .control])))
        XCTAssertEqual(f.recorder.calls, ["copy", "paste", "selectAll", "undo", "redo", "null"])
    }

    func testTextFieldFocusKeepsCommandCAwayFromTheGrid() {
        let f = makeFixture()
        XCTAssertTrue(f.window.makeFirstResponder(f.field))
        XCTAssertFalse(f.table.ownsKeyboardFocus)

        _ = f.table.performKeyEquivalent(with: key("c", .command))
        _ = f.table.performKeyEquivalent(with: key("z", .command))
        _ = f.table.performKeyEquivalent(with: key("n", [.command, .control]))
        XCTAssertEqual(f.recorder.calls, [], "the WHERE field / find bar owns ⌘C, ⌘Z and ⌃⌘N")
    }

    /// A cell-editor popover is its own key window: the grid's window stays
    /// main but not key, so ⌘C belongs to the popover's text field.
    func testGridStandsDownWhileAnotherWindowIsKey() {
        let f = makeFixture()
        XCTAssertTrue(f.window.makeFirstResponder(f.table))
        f.window.pretendKey = false
        XCTAssertFalse(f.table.ownsKeyboardFocus)

        _ = f.table.performKeyEquivalent(with: key("c", .command))
        XCTAssertEqual(f.recorder.calls, [])
    }

    func testDetachedTableClaimsNothing() {
        let table = EditableTableView()
        let recorder = Recorder()
        table.handler = recorder
        _ = table.performKeyEquivalent(with: key("c", .command))
        XCTAssertEqual(recorder.calls, [])
    }

    func testUnrelatedEquivalentsFallThrough() {
        let f = makeFixture()
        XCTAssertTrue(f.window.makeFirstResponder(f.table))
        XCTAssertFalse(f.table.performKeyEquivalent(with: key("s", .command)), "⌘S is the tab's Apply, not the grid's")
        XCTAssertFalse(f.table.performKeyEquivalent(with: key("c", [.command, .option])))
        XCTAssertEqual(f.recorder.calls, [])
    }

    func testKeyboardNavigationAndTypeToEdit() {
        let f = makeFixture()
        XCTAssertTrue(f.window.makeFirstResponder(f.table))
        f.table.keyDown(with: key("\t", [], keyCode: 48))
        f.table.keyDown(with: key("\t", .shift, keyCode: 48))
        f.table.keyDown(with: key("\r", [], keyCode: 36))
        f.table.keyDown(with: key("\r", .shift, keyCode: 36))
        f.table.keyDown(with: key("\u{F701}", .shift, keyCode: 125))
        f.table.keyDown(with: key("\u{7F}", [], keyCode: 51))
        f.table.keyDown(with: key("\u{7F}", .command, keyCode: 51))
        f.table.keyDown(with: key("x", [], keyCode: 7))
        f.table.keyDown(with: key("\u{F705}", [], keyCode: 120))
        XCTAssertEqual(f.recorder.calls, [
            "move 0,1 wrap", "move 0,-1 wrap", "edit -", "move -1,0",
            "move 1,0 extend", "null", "deleteRows", "edit x", "edit -",
        ])
    }

    func testPrintableFilter() {
        XCTAssertTrue(EditableTableView.isPrintable("a"))
        XCTAssertTrue(EditableTableView.isPrintable("é"))
        XCTAssertFalse(EditableTableView.isPrintable("\u{F700}"))
        XCTAssertFalse(EditableTableView.isPrintable("\u{1B}"))
        XCTAssertFalse(EditableTableView.isPrintable(""))
    }
}
