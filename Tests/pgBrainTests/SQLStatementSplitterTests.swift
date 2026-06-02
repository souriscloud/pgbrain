import XCTest
@testable import pgBrain

/// Pure, no-DB coverage of the statement splitter: quote/comment/dollar-quote
/// awareness, `BEGIN ATOMIC` bodies, and caret lookup.
final class SQLStatementSplitterTests: XCTestCase {

    private func trimmed(_ buffer: String) -> [String] {
        SQLStatementSplitter.split(buffer).map(\.trimmed)
    }

    func testBasicSplitAndTrim() {
        XCTAssertEqual(trimmed("SELECT 1; SELECT 2;"), ["SELECT 1", "SELECT 2"])
    }

    func testTrailingStatementWithoutSemicolon() {
        XCTAssertEqual(trimmed("SELECT 1; SELECT 2"), ["SELECT 1", "SELECT 2"])
    }

    func testEmptySpansDropped() {
        XCTAssertEqual(trimmed(";;  ;\nSELECT 1;;"), ["SELECT 1"])
        XCTAssertEqual(trimmed("   \n  "), [])
    }

    func testSemicolonInsideSingleQuoteDoesNotSplit() {
        XCTAssertEqual(trimmed("SELECT 'a;b;c'; SELECT 2"),
                       ["SELECT 'a;b;c'", "SELECT 2"])
    }

    func testEscapedQuoteInsideString() {
        XCTAssertEqual(trimmed("SELECT 'it''s; fine'; SELECT 2"),
                       ["SELECT 'it''s; fine'", "SELECT 2"])
    }

    func testSemicolonInsideDoubleQuotedIdentifier() {
        XCTAssertEqual(trimmed("SELECT * FROM \"weird;name\"; SELECT 2"),
                       ["SELECT * FROM \"weird;name\"", "SELECT 2"])
    }

    func testSemicolonInsideLineComment() {
        XCTAssertEqual(trimmed("SELECT 1 -- a;b\n; SELECT 2"),
                       ["SELECT 1 -- a;b", "SELECT 2"])
    }

    func testSemicolonInsideNestedBlockComment() {
        XCTAssertEqual(trimmed("SELECT 1 /* a; /* nested; */ b; */; SELECT 2"),
                       ["SELECT 1 /* a; /* nested; */ b; */", "SELECT 2"])
    }

    func testSemicolonInsideDollarQuote() {
        XCTAssertEqual(trimmed("SELECT $$ a; b; c $$; SELECT 2"),
                       ["SELECT $$ a; b; c $$", "SELECT 2"])
    }

    func testSemicolonInsideTaggedDollarQuote() {
        XCTAssertEqual(trimmed("SELECT $body$ x; y $body$; SELECT 2"),
                       ["SELECT $body$ x; y $body$", "SELECT 2"])
    }

    func testDollarThatIsNotAQuoteTag() {
        // `$1` is a bind placeholder, not a dollar-quote opener — must still split.
        XCTAssertEqual(trimmed("SELECT $1; SELECT $2"), ["SELECT $1", "SELECT $2"])
    }

    func testBeginAtomicBodyKeepsInternalSemicolons() {
        let sql = """
        CREATE FUNCTION f() RETURNS int LANGUAGE sql BEGIN ATOMIC SELECT 1; SELECT 2; END;
        SELECT 99;
        """
        let parts = trimmed(sql)
        XCTAssertEqual(parts.count, 2, "the BEGIN ATOMIC body must not split")
        XCTAssertTrue(parts[0].contains("BEGIN ATOMIC"))
        XCTAssertTrue(parts[0].hasSuffix("END"))
        XCTAssertEqual(parts[1], "SELECT 99")
    }

    func testBeginAtomicWithCaseEndNesting() {
        let sql = "CREATE FUNCTION f() RETURNS int LANGUAGE sql BEGIN ATOMIC " +
                  "SELECT CASE WHEN true THEN 1 ELSE 2 END; END; SELECT 7;"
        let parts = trimmed(sql)
        XCTAssertEqual(parts.count, 2)
        XCTAssertEqual(parts[1], "SELECT 7")
    }

    func testBareBeginIsNotAtomicAndSplitsNormally() {
        // A transaction-control BEGIN is a normal word; `begin` mid-identifier
        // also must not be mistaken for the keyword.
        XCTAssertEqual(trimmed("BEGIN; SELECT 1; COMMIT;"),
                       ["BEGIN", "SELECT 1", "COMMIT"])
    }

    // MARK: lexer edge cases (bare operators, unterminated spans)

    func testBareMinusAndSlashAreNotComments() {
        // `a - b` and `b / c` must not be mistaken for `--` / `/*`.
        XCTAssertEqual(trimmed("SELECT a - b / c; SELECT 2"),
                       ["SELECT a - b / c", "SELECT 2"])
    }

    func testEscapedDoubleQuoteInIdentifier() {
        XCTAssertEqual(trimmed("SELECT \"a\"\"b\" FROM t; SELECT 2"),
                       ["SELECT \"a\"\"b\" FROM t", "SELECT 2"])
    }

    func testLineCommentAtEndOfBufferWithoutNewline() {
        XCTAssertEqual(trimmed("SELECT 1 -- trailing comment"),
                       ["SELECT 1 -- trailing comment"])
    }

    func testUnterminatedSingleQuoteConsumesToEnd() {
        XCTAssertEqual(trimmed("SELECT 'abc"), ["SELECT 'abc"])
    }

    func testUnterminatedDoubleQuoteConsumesToEnd() {
        XCTAssertEqual(trimmed("SELECT \"abc"), ["SELECT \"abc"])
    }

    func testUnterminatedDollarQuoteConsumesToEnd() {
        XCTAssertEqual(trimmed("SELECT $$ abc; def"), ["SELECT $$ abc; def"])
    }

    func testAtomicBodyWithCommentsStringsAndDollarQuotes() {
        // Exercises the quote/line-comment/block-comment/dollar/bare-operator
        // branches inside the BEGIN ATOMIC scanner in one shot.
        let sql = """
        CREATE FUNCTION f() RETURNS int LANGUAGE sql BEGIN ATOMIC
          SELECT a - b / c;
          -- a line; comment
          /* a block; comment */
          SELECT $q$ dollar; body $q$ WHERE x = $1;
          SELECT 'str;';
        END;
        SELECT 99;
        """
        let parts = trimmed(sql)
        XCTAssertEqual(parts.count, 2)
        XCTAssertTrue(parts[0].hasSuffix("END"))
        XCTAssertEqual(parts[1], "SELECT 99")
    }

    func testUnterminatedAtomicBodyConsumesToEnd() {
        let sql = "CREATE FUNCTION f() RETURNS int LANGUAGE sql BEGIN ATOMIC SELECT 1; SELECT 2;"
        // No closing END → the whole thing is one (unterminated) statement.
        XCTAssertEqual(trimmed(sql).count, 1)
    }

    // MARK: statementAt(caret:)

    func testStatementAtCaretInsideRange() {
        let buf = "SELECT 1; SELECT 2;"
        let caret = buf.index(buf.startIndex, offsetBy: 3) // inside "SELECT 1"
        XCTAssertEqual(SQLStatementSplitter.statementAt(caret: caret, in: buf)?.trimmed, "SELECT 1")
    }

    func testStatementAtCaretBetweenPicksPreceding() {
        let buf = "SELECT 1; SELECT 2;"
        // The ';' at index 8 falls outside every statement range (a statement's
        // range stops before its terminator and the next starts after it), so the
        // lookup takes its "nearest preceding statement" fallback path.
        let caret = buf.index(buf.startIndex, offsetBy: 8)
        XCTAssertEqual(SQLStatementSplitter.statementAt(caret: caret, in: buf)?.trimmed, "SELECT 1")
    }

    func testStatementAtCaretBeforeEverythingPicksFirst() {
        let buf = "   SELECT 1;"
        XCTAssertEqual(SQLStatementSplitter.statementAt(caret: buf.startIndex, in: buf)?.trimmed,
                       "SELECT 1")
    }

    func testStatementAtEmptyBufferIsNil() {
        XCTAssertNil(SQLStatementSplitter.statementAt(caret: "".startIndex, in: ""))
    }
}
