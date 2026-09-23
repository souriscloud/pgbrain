import XCTest
@testable import pgBrain

final class C_GridSelectionTests: XCTestCase {
    private func c(_ r: Int, _ col: Int) -> GridSelection.Cell { .init(row: r, col: col) }

    // MARK: - Selection model

    func testClickShiftClickMakesARectangle() {
        var s = GridSelection()
        s.select(c(1, 1))
        XCTAssertTrue(s.isSingleCell)
        s.extend(to: c(3, 2))
        XCTAssertEqual(s.rows, [1, 2, 3])
        XCTAssertEqual(s.cols, [1, 2])
        XCTAssertEqual(s.cells.count, 6)
        XCTAssertEqual(s.anchor, c(1, 1))
        XCTAssertEqual(s.cursor, c(3, 2))
        s.extend(to: c(0, 0))
        XCTAssertEqual(s.rows, [0, 1])
        XCTAssertEqual(s.cols, [0, 1])
    }

    func testCommandClickAddsAndRemovesCells() {
        var s = GridSelection()
        s.select(c(0, 0))
        s.add(c(2, 2))
        XCTAssertEqual(s.ranges.count, 2)
        XCTAssertTrue(s.contains(c(2, 2)))
        XCTAssertFalse(s.contains(c(1, 1)))
        s.add(c(2, 2))
        XCTAssertFalse(s.contains(c(2, 2)), "⌘-clicking a lone selected cell deselects it")
        XCTAssertTrue(s.contains(c(0, 0)))
    }

    func testSelectAllAndRows() {
        var s = GridSelection()
        s.selectAll(rows: 3, cols: 4)
        XCTAssertEqual(s.cells.count, 12)
        s.selectRows(from: 2, to: 1, cols: 4)
        XCTAssertEqual(s.rows, [1, 2])
        XCTAssertEqual(s.cols, [0, 1, 2, 3])
        s.selectRows(from: 4, to: 4, cols: 4, adding: true)
        XCTAssertEqual(s.rows, [1, 2, 4])
    }

    func testArrowAndTabMovement() {
        var s = GridSelection()
        s.move(rowDelta: 1, colDelta: 0, rows: 3, cols: 3)
        XCTAssertEqual(s.cursor, c(0, 0), "first key press lands on the first cell")
        s.move(rowDelta: 0, colDelta: 5, rows: 3, cols: 3)
        XCTAssertEqual(s.cursor, c(0, 2), "clamped at the edge")
        s.move(rowDelta: 0, colDelta: 1, rows: 3, cols: 3, wrap: true)
        XCTAssertEqual(s.cursor, c(1, 0), "Tab wraps onto the next row")
        s.move(rowDelta: 0, colDelta: -1, rows: 3, cols: 3, wrap: true)
        XCTAssertEqual(s.cursor, c(0, 2), "⇧Tab wraps back")
        s.move(rowDelta: 1, colDelta: 0, rows: 3, cols: 3, extend: true)
        XCTAssertEqual(s.anchor, c(0, 2))
        XCTAssertEqual(s.rows, [0, 1])
        s.move(rowDelta: 1, colDelta: 0, rows: 3, cols: 3)
        XCTAssertTrue(s.isSingleCell, "a plain arrow collapses the range")
    }

    func testClampAfterRowsVanish() {
        var s = GridSelection()
        s.select(c(1, 1))
        s.extend(to: c(5, 3))
        s.clamp(rows: 3, cols: 2)
        XCTAssertEqual(s.rows, [1, 2])
        XCTAssertEqual(s.cols, [1])
        s.clamp(rows: 0, cols: 2)
        XCTAssertTrue(s.isEmpty)
    }

    // MARK: - Copy

    func testCopyUsesValuesProviderAndNullToken() {
        var s = GridSelection()
        s.select(c(0, 0))
        s.extend(to: c(1, 1))
        let data: [[String?]] = [["a", nil], ["tab\there", "say \"hi\""]]
        let tsv = GridClipboard.tsv(for: s, value: { data[$0.row][$0.col] }, nullToken: "")
        XCTAssertEqual(tsv, "a\t\n\"tab\there\"\t\"say \"\"hi\"\"\"")
        let tokenised = GridClipboard.tsv(for: s, value: { data[$0.row][$0.col] }, nullToken: "NULL")
        XCTAssertTrue(tokenised.hasPrefix("a\tNULL\n"))
    }

    func testMultiRangeCopyKeepsItsShape() {
        var s = GridSelection()
        s.select(c(0, 0))
        s.add(c(2, 2))
        let tsv = GridClipboard.tsv(for: s, value: { "r\($0.row)c\($0.col)" }, nullToken: "")
        XCTAssertEqual(tsv, "r0c0\t\n\tr2c2")
    }

    // MARK: - Paste

    func testParseRoundTripsCopy() {
        let rows: [[String]] = [["a", ""], ["multi\nline", "q\"uote"], ["x\ty", "z"]]
        let text = rows.map { $0.map(GridClipboard.encodeField).joined(separator: "\t") }.joined(separator: "\n")
        XCTAssertEqual(GridClipboard.parse(text), rows)
        XCTAssertEqual(GridClipboard.parse("1\t2\r\n3\t4\r\n"), [["1", "2"], ["3", "4"]], "CRLF + trailing newline")
        XCTAssertEqual(GridClipboard.parse(""), [])
        XCTAssertEqual(GridClipboard.parse("solo"), [["solo"]])
    }

    func testPasteBlockFromOriginIsClippedAtTheEdge() {
        var s = GridSelection()
        s.select(c(1, 1))
        let plan = GridClipboard.plan([["a", "b", "c"], ["d", "e", "f"]], into: s, rowCount: 2, colCount: 3)
        XCTAssertEqual(plan.cells.map(\.cell), [c(1, 1), c(1, 2)])
        XCTAssertEqual(plan.cells.map(\.text), ["a", "b"])
        XCTAssertEqual(plan.clipped, 4)
    }

    func testSingleValueFillsTheWholeSelection() {
        var s = GridSelection()
        s.select(c(0, 0))
        s.extend(to: c(1, 1))
        let plan = GridClipboard.plan([["z"]], into: s, rowCount: 5, colCount: 5)
        XCTAssertEqual(plan.cells.count, 4)
        XCTAssertTrue(plan.cells.allSatisfy { $0.text == "z" })
        XCTAssertEqual(plan.clipped, 0)
    }

    func testPasteStartsAtTopLeftOfSelection() {
        var s = GridSelection()
        s.select(c(3, 2))
        s.extend(to: c(1, 0))
        let plan = GridClipboard.plan([["a", "b"]], into: s, rowCount: 10, colCount: 10)
        XCTAssertEqual(plan.cells.map(\.cell), [c(1, 0), c(1, 1)])
    }

    func testPasteIntoEmptySelectionDoesNothing() {
        let plan = GridClipboard.plan([["a"]], into: GridSelection(), rowCount: 3, colCount: 3)
        XCTAssertTrue(plan.cells.isEmpty)
    }
}
