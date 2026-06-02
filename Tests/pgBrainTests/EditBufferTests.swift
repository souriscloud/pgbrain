import XCTest
@testable import pgBrain

@MainActor
final class EditBufferTests: XCTestCase {

    func testStageLiteralAndRead() {
        let b = EditBuffer()
        XCTAssertFalse(b.isDirty)
        b.set(row: 0, column: 1, value: "hi")
        XCTAssertTrue(b.isDirty)
        XCTAssertEqual(b.dirtyCount, 1)
        XCTAssertTrue(b.isDirty(row: 0, column: 1))
        XCTAssertEqual(b.value(row: 0, column: 1), .some("hi"))
        XCTAssertEqual(b.entry(row: 0, column: 1), .literal("hi"))
    }

    func testCleanCellReadsNone() {
        let b = EditBuffer()
        XCTAssertEqual(b.value(row: 9, column: 9), .none)
        XCTAssertNil(b.entry(row: 9, column: 9))
        XCTAssertFalse(b.isDirty(row: 9, column: 9))
    }

    func testTypedStagingCoversEveryKind() {
        let b = EditBuffer()
        b.set(row: 0, column: 0, typed: .literal("x"))
        b.set(row: 0, column: 1, typed: .null)
        b.set(row: 0, column: 2, typed: .expression("now()"))
        b.set(row: 0, column: 3, typed: .defaultKeyword)

        XCTAssertEqual(b.entry(row: 0, column: 0), .literal("x"))
        XCTAssertEqual(b.entry(row: 0, column: 1), .literal(nil))      // explicit NULL
        XCTAssertEqual(b.value(row: 0, column: 1), .some(nil))         // renders as NULL
        XCTAssertEqual(b.entry(row: 0, column: 2), .expression("now()"))
        XCTAssertEqual(b.entry(row: 0, column: 3), .defaultKeyword)
    }

    func testDisplayValuePerKind() {
        XCTAssertEqual(EditBuffer.Entry.literal("v").displayValue, "v")
        XCTAssertEqual(EditBuffer.Entry.literal(nil).displayValue, nil)
        XCTAssertEqual(EditBuffer.Entry.expression("f()").displayValue, "f()")
        XCTAssertEqual(EditBuffer.Entry.defaultKeyword.displayValue, "DEFAULT")
    }

    func testIsSpecial() {
        let b = EditBuffer()
        b.set(row: 0, column: 0, value: "lit")
        b.set(row: 0, column: 1, typed: .expression("now()"))
        b.set(row: 0, column: 2, typed: .defaultKeyword)
        XCTAssertFalse(b.isSpecial(row: 0, column: 0))   // literal
        XCTAssertTrue(b.isSpecial(row: 0, column: 1))    // expression
        XCTAssertTrue(b.isSpecial(row: 0, column: 2))    // DEFAULT
        XCTAssertFalse(b.isSpecial(row: 5, column: 5))   // clean
    }

    func testClearCell() {
        let b = EditBuffer()
        b.set(row: 0, column: 0, value: "v")
        b.clearCell(row: 0, column: 0)
        XCTAssertFalse(b.isDirty)
        XCTAssertTrue(b.canUndo, "clearing a cell is itself undoable")
        b.clearCell(row: 9, column: 9)   // no-op on a clean cell
    }

    func testEditsByRowGroupingAndOrdering() {
        let b = EditBuffer()
        b.set(row: 1, column: 2, value: "b")
        b.set(row: 0, column: 1, value: "a")
        b.set(row: 0, column: 0, value: "a0")
        let grouped = b.editsByRow()
        XCTAssertEqual(grouped.map(\.row), [0, 1])                 // rows sorted
        XCTAssertEqual(grouped[0].cells.map(\.column), [0, 1])     // cells sorted
        XCTAssertEqual(grouped[1].cells.first?.column, 2)
    }

    func testUndoRestoresPriorThenClears() {
        let b = EditBuffer()
        b.set(row: 0, column: 0, value: "first")
        b.set(row: 0, column: 0, value: "second")   // overwrites; prior was "first"
        XCTAssertEqual(b.undo(), EditBuffer.CellKey(row: 0, column: 0))
        XCTAssertEqual(b.entry(row: 0, column: 0), .literal("first"))   // restored
        _ = b.undo()                                                    // back to cleanSlate
        XCTAssertNil(b.entry(row: 0, column: 0))
        XCTAssertFalse(b.canUndo)
        XCTAssertNil(b.undo(), "undo on empty history returns nil")
    }

    func testClearWipesEverything() {
        let b = EditBuffer()
        b.set(row: 0, column: 0, value: "v")
        b.clear()
        XCTAssertFalse(b.isDirty)
        XCTAssertFalse(b.canUndo)
    }
}
