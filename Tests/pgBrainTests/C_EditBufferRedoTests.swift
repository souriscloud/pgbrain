import XCTest
@testable import pgBrain

@MainActor
final class C_EditBufferRedoTests: XCTestCase {
    private func key(_ r: Int, _ c: Int) -> EditBuffer.CellKey { .init(row: r, column: c) }

    func testRedoReappliesWhatUndoReverted() {
        let b = EditBuffer()
        b.set(row: 0, column: 0, value: "a")
        b.set(row: 0, column: 0, value: "b")
        XCTAssertFalse(b.canRedo)
        XCTAssertEqual(b.undo(), key(0, 0))
        XCTAssertEqual(b.entry(row: 0, column: 0), .literal("a"))
        XCTAssertTrue(b.canRedo)
        XCTAssertEqual(b.redo(), key(0, 0))
        XCTAssertEqual(b.entry(row: 0, column: 0), .literal("b"))
        XCTAssertFalse(b.canRedo)
        XCTAssertNil(b.redo())
    }

    func testRedoAfterUndoToCleanAndOfAClear() {
        let b = EditBuffer()
        b.set(row: 1, column: 2, typed: .expression("now()"))
        b.clearCell(row: 1, column: 2)
        _ = b.undo()
        XCTAssertEqual(b.entry(row: 1, column: 2), .expression("now()"))
        _ = b.undo()
        XCTAssertFalse(b.isDirty)
        _ = b.redo()
        _ = b.redo()
        XCTAssertFalse(b.isDirty, "redo replays the clear too")
    }

    func testNewEditDropsRedoStack() {
        let b = EditBuffer()
        b.set(row: 0, column: 0, value: "a")
        _ = b.undo()
        XCTAssertTrue(b.canRedo)
        b.set(row: 0, column: 1, value: "x")
        XCTAssertFalse(b.canRedo)
    }

    func testBatchIsOneUndoStep() {
        let b = EditBuffer()
        b.batch {
            b.set(row: 0, column: 0, typed: .null)
            b.set(row: 1, column: 0, typed: .null)
            b.set(row: 2, column: 0, typed: .null)
        }
        XCTAssertEqual(b.dirtyCount, 3)
        XCTAssertEqual(b.undoDepth, 1)
        _ = b.undo()
        XCTAssertFalse(b.isDirty)
        _ = b.redo()
        XCTAssertEqual(b.dirtyCount, 3)
    }

    func testApplyChangesIsOneStepAndSkipsNoOps() {
        let b = EditBuffer()
        b.apply([
            .init(key: key(0, 0), state: .staged(.literal("v"))),
            .init(key: key(0, 1), state: .clean),
        ])
        XCTAssertEqual(b.undoDepth, 1)
        XCTAssertEqual(b.dirtyCount, 1)
        b.apply([.init(key: key(0, 1), state: .clean)])
        XCTAssertEqual(b.undoDepth, 1, "a change to the same state isn't a step")
    }

    /// The form stages on every keystroke; ⌘Z undoes the field, not a letter.
    func testCoalescedTypingIsOneStepPerField() {
        let b = EditBuffer()
        for text in ["h", "he", "hel", "hell", "hello"] {
            b.set(row: 0, column: 0, typed: .literal(text), coalesce: true)
        }
        b.set(row: 0, column: 1, typed: .literal("x"), coalesce: true)
        XCTAssertEqual(b.undoDepth, 2)
        _ = b.undo()
        XCTAssertEqual(b.entry(row: 0, column: 0), .literal("hello"))
        XCTAssertNil(b.entry(row: 0, column: 1))
        _ = b.undo()
        XCTAssertNil(b.entry(row: 0, column: 0))
        _ = b.redo()
        XCTAssertEqual(b.entry(row: 0, column: 0), .literal("hello"))
    }

    func testCoalescingBackToOriginalRemovesTheStep() {
        let b = EditBuffer()
        b.set(row: 0, column: 0, typed: .literal("a"), coalesce: true)
        b.clearCell(row: 0, column: 0, coalesce: true)
        XCTAssertEqual(b.undoDepth, 0)
        XCTAssertFalse(b.isDirty)
    }

    func testSettleAppliedKeepsEditsMadeDuringApply() {
        let b = EditBuffer()
        b.set(row: 0, column: 0, value: "sent")
        b.set(row: 1, column: 0, value: "sent too")
        let submitted = b.edits
        b.set(row: 1, column: 0, value: "changed while applying")
        b.set(row: 2, column: 0, value: "new while applying")
        b.settleApplied(submitted)
        XCTAssertNil(b.entry(row: 0, column: 0))
        XCTAssertEqual(b.entry(row: 1, column: 0), .literal("changed while applying"))
        XCTAssertEqual(b.entry(row: 2, column: 0), .literal("new while applying"))
        XCTAssertFalse(b.canUndo, "history resets after a commit")
    }

    func testRemapRowsFollowsRemovedRows() {
        let b = EditBuffer()
        b.set(row: 0, column: 0, value: "a")
        b.set(row: 2, column: 0, value: "c")
        b.set(row: 3, column: 1, value: "d")
        let map = RowsLoader.indexMapping(removing: [1, 2], count: 4)
        XCTAssertEqual(map, [0: 0, 3: 1])
        b.remapRows { map[$0] }
        XCTAssertEqual(b.entry(row: 0, column: 0), .literal("a"))
        XCTAssertEqual(b.entry(row: 1, column: 1), .literal("d"))
        XCTAssertEqual(b.dirtyCount, 2)
        _ = b.undo()
        XCTAssertNil(b.entry(row: 1, column: 1), "undo history was re-keyed too")
    }

    func testChangeSignals() {
        let b = EditBuffer()
        var fired = 0
        b.onChange = { fired += 1 }
        let v0 = b.version, ext0 = b.externalRevision
        b.set(row: 0, column: 0, value: "a")
        XCTAssertEqual(fired, 1)
        XCTAssertGreaterThan(b.version, v0)
        XCTAssertEqual(b.externalRevision, ext0, "direct staging doesn't force editors to re-hydrate")
        _ = b.undo()
        XCTAssertEqual(fired, 2)
        XCTAssertGreaterThan(b.externalRevision, ext0)
    }

    func testEntryTypedRoundTrip() {
        let values: [TypedInputValue] = [.literal("x"), .literal(""), .null, .expression("now()"), .defaultKeyword]
        for v in values { XCTAssertEqual(EditBuffer.Entry(v).typed, v) }
        XCTAssertEqual(TypedInputValue(serverValue: nil), .null)
        XCTAssertEqual(TypedInputValue(serverValue: "7"), .literal("7"))
        XCTAssertEqual(UpdateApplier.CellChange.Value(.literal(nil)), .literal(nil))
        XCTAssertEqual(UpdateApplier.CellChange.Value(.defaultKeyword), .defaultKeyword)
    }
}
