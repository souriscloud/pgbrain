import XCTest
@testable import pgBrain

/// Pure coverage of the shared `SQLLexer` and of the three consumers routed
/// through it (splitter, safety classifier, completion tokenizer, formatter).
final class A_SQLLexerTests: XCTestCase {

    private func kinds(_ s: String) -> [SQLLexer.Kind] {
        SQLLexer.lex(s).map(\.kind).filter { $0 != .whitespace }
    }
    private func split(_ s: String) -> [String] { SQLStatementSplitter.split(s).map(\.trimmed) }

    // MARK: lexer

    func testEscapeStringWithBackslashQuote() {
        XCTAssertEqual(kinds("E'a\\';b'"), [.string])
        XCTAssertEqual(kinds("e'x\\\\' y"), [.string, .word])
    }

    func testStandardStringDoesNotHonourBackslash() {
        // 'a\' is a complete standard string; `;` then splits.
        XCTAssertEqual(kinds("'a\\';"), [.string, .punct])
    }

    func testPrefixedLiterals() {
        XCTAssertEqual(kinds("B'101' X'ff' N'x' U&'d\\0061'"), [.string, .string, .string, .string])
        XCTAssertEqual(kinds("U&\"d\\0061t\""), [.quotedIdent])
    }

    func testDollarQuotesVersusParamsAndIdentifiers() {
        XCTAssertEqual(kinds("$$a;b$$"), [.dollarString])
        XCTAssertEqual(kinds("$fn$ x $$ y $fn$"), [.dollarString])
        XCTAssertEqual(kinds("$1"), [.parameter])
        XCTAssertEqual(kinds("$1 + $22"), [.parameter, .op, .parameter])
        XCTAssertEqual(kinds("a$b"), [.word])
        XCTAssertEqual(kinds("a$b$c"), [.word])
        // `$1$` must not open a dollar quote (tags can't start with a digit).
        XCTAssertEqual(kinds("$1$x"), [.parameter, .op, .word])
    }

    func testNestedBlockComment() {
        XCTAssertEqual(kinds("/* a /* b */ c */ x"), [.blockComment, .word])
    }

    func testLineCommentStopsAtCRLF() {
        let toks = SQLLexer.lex("-- c\r\nx")
        XCTAssertEqual(toks.first?.kind, .lineComment)
        XCTAssertEqual(toks.first?.range.length, 4)
        XCTAssertEqual(toks.last?.kind, .word)
        XCTAssertEqual(kinds("-- c\rSELECT"), [.lineComment, .word])
    }

    func testQuotedIdentBody() {
        let u = Array("\"a\"\"b\"".utf16)
        let t = SQLLexer.lex(utf16: u)[0]
        XCTAssertEqual(SQLLexer.quotedIdentBody(t, in: u), "a\"b")
    }

    func testNonASCIIIdentifiers() {
        XCTAssertEqual(kinds("čau žluťoučký"), [.word, .word])
    }

    func testNumbers() {
        XCTAssertEqual(kinds("1 1.5 .5 1e10 1.5E-3 0x1F 1_000"), Array(repeating: .number, count: 7))
        XCTAssertEqual(kinds("1..2"), [.number, .punct, .number])
    }

    // MARK: splitter

    func testSplitterHonoursEscapeStrings() {
        XCTAssertEqual(split("SELECT E'a\\';b'; SELECT 2"), ["SELECT E'a\\';b'", "SELECT 2"])
    }

    func testSplitterCRLFLineComment() {
        XCTAssertEqual(split("SELECT 1 -- x;y\r\n; SELECT 2"), ["SELECT 1 -- x;y", "SELECT 2"])
        XCTAssertEqual(split("SELECT 1; -- c\r\nSELECT 2;"), ["SELECT 1", "-- c\r\nSELECT 2"])
    }

    func testSplitterParamsAndDollarIdents() {
        XCTAssertEqual(split("SELECT $1; SELECT a$b FROM t; SELECT 3"),
                       ["SELECT $1", "SELECT a$b FROM t", "SELECT 3"])
        // `a$b$` must not be mistaken for a dollar-quote opener.
        XCTAssertEqual(split("SELECT a$b$c; SELECT 2"), ["SELECT a$b$c", "SELECT 2"])
    }

    func testSplitterBeginAtomicWithCommentBetween() {
        let sql = "CREATE FUNCTION f() RETURNS int LANGUAGE sql BEGIN /*x*/ ATOMIC SELECT 1; END; SELECT 2"
        XCTAssertEqual(split(sql).count, 2)
    }

    func testSplitterRangesWithMultibyteText() {
        let buf = "SELECT 'žluť'; SELECT 2"
        let stmts = SQLStatementSplitter.split(buf)
        XCTAssertEqual(stmts.count, 2)
        XCTAssertEqual(String(buf[stmts[0].range]), "SELECT 'žluť'")
        XCTAssertEqual(String(buf[stmts[1].range]).trimmingCharacters(in: .whitespaces), "SELECT 2")
    }

    // MARK: tokenizer compatibility

    func testTokenizerEscapeStringIsOneToken() {
        XCTAssertEqual(SQLTokenizer.tokenize("E'it\\'s' x").map(\.kind), [.string, .identifier("x")])
    }

    func testTokenizerNestedCommentIsOneToken() {
        XCTAssertEqual(SQLTokenizer.tokenize("/* a /* b */ c */ x").map(\.kind), [.comment, .identifier("x")])
    }

    // MARK: SQLSafety.tokens

    func testSafetyTokensSkipEscapeString() {
        XCTAssertEqual(SQLSafety.tokens(in: "SELECT E'\\' delete from t' AS x"), ["SELECT", "AS", "x"])
    }
}

/// Classifier regressions: things that must never be `.readOnly`.
final class A_SQLSafetyClassifyTests: XCTestCase {
    private func v(_ s: String) -> SQLSafety.Verdict { SQLSafety.classify(s) }

    func testDataModifyingCTEsAreNotReadOnly() {
        XCTAssertEqual(v("WITH x AS (SELECT 1) INSERT INTO t SELECT * FROM x"), .write)
        XCTAssertEqual(v("WITH d AS (DELETE FROM t WHERE id = 1 RETURNING *) SELECT * FROM d"), .write)
        XCTAssertEqual(v("WITH d AS (DELETE FROM t RETURNING *) SELECT * FROM d WHERE id = 1"),
                       .destructiveUnscoped, "outer WHERE doesn't scope the CTE's DELETE")
        XCTAssertEqual(v("WITH m AS (MERGE INTO t USING s ON t.id = s.id WHEN MATCHED THEN DELETE) SELECT 1"), .write)
        XCTAssertEqual(v("WITH i AS (INSERT INTO t VALUES (1) RETURNING id) SELECT * FROM i"), .write)
    }

    func testSelectIntoIsNotReadOnly() {
        XCTAssertEqual(v("SELECT * INTO new_table FROM t"), .ddl)
        XCTAssertEqual(v("WITH a AS (SELECT 1) SELECT * INTO new_t FROM a"), .ddl)
    }

    func testSelectForUpdateStaysReadOnly() {
        XCTAssertEqual(v("SELECT * FROM t WHERE id = 1 FOR UPDATE"), .readOnly)
        XCTAssertEqual(v("SELECT * FROM t FOR NO KEY UPDATE SKIP LOCKED"), .readOnly)
        XCTAssertEqual(v("SELECT * FROM t FOR SHARE"), .readOnly)
    }

    func testOtherNonReadVerbs() {
        for sql in ["MERGE INTO t USING s ON t.id = s.id WHEN MATCHED THEN UPDATE SET x = 1",
                    "COPY t FROM STDIN", "CALL p()", "DO $$ BEGIN END $$", "SET search_path = x",
                    "LOCK TABLE t", "BEGIN", "NOTIFY c", "ANALYZE t"] {
            XCTAssertNotEqual(v(sql), .readOnly, sql)
        }
        for sql in ["REFRESH MATERIALIZED VIEW mv", "COMMENT ON TABLE t IS 'x'", "CLUSTER t"] {
            XCTAssertEqual(v(sql), .ddl, sql)
        }
    }

    func testExplainAnalyzeExecutes() {
        XCTAssertEqual(v("EXPLAIN SELECT 1"), .readOnly)
        XCTAssertEqual(v("EXPLAIN DELETE FROM t"), .readOnly, "plain EXPLAIN doesn't execute")
        XCTAssertEqual(v("EXPLAIN ANALYZE DELETE FROM t"), .destructiveUnscoped)
        XCTAssertEqual(v("EXPLAIN (ANALYZE, BUFFERS) UPDATE t SET x = 1 WHERE id = 2"), .write)
    }

    func testWhereInScalarSubqueryDoesNotScopeUpdate() {
        XCTAssertEqual(v("UPDATE t SET x = (SELECT y FROM z WHERE z.id = 1)"), .destructiveUnscoped)
    }

    func testInsertOnConflictDoUpdateIsWrite() {
        XCTAssertEqual(v("INSERT INTO t VALUES (1) ON CONFLICT (id) DO UPDATE SET x = 2"), .write)
    }

    func testParenthesisedSelect() {
        XCTAssertEqual(v("(SELECT 1) UNION (SELECT 2)"), .readOnly)
        XCTAssertEqual(v(";"), .readOnly)
    }

    func testEscapeStringDoesNotHideVerb() {
        // Old lexer ended the string at \' and then saw `delete from t` as code.
        XCTAssertEqual(v("SELECT E'it\\'s; delete from t'"), .readOnly)
    }

    func testAutoLimitIsNeverAppliedToWrites() {
        // QueryRunner only auto-LIMITs .readOnly statements.
        for sql in ["WITH d AS (DELETE FROM t WHERE a=1 RETURNING *) SELECT * FROM d",
                    "SELECT * INTO x FROM t"] {
            XCTAssertNotEqual(v(sql), .readOnly, sql)
        }
    }
}

/// Formatter must never glue code onto a `--` comment.
@MainActor
final class A_SQLFormatterTests: XCTestCase {
    func testLineCommentFollowedByNewline() {
        let out = SQLFormatter.format("SELECT id, -- pk\n name FROM t")
        XCTAssertFalse(out.contains("-- pk name"), out)
        XCTAssertTrue(out.contains("-- pk\n"), out)
        XCTAssertTrue(out.contains("name"), out)
        // Every line that holds `--` must contain nothing after the comment text.
        for line in out.split(separator: "\n") where line.contains("--") {
            XCTAssertTrue(line.hasSuffix("-- pk"), String(line))
        }
    }

    func testTrailingLineCommentBeforeClause() {
        let out = SQLFormatter.format("select a -- note\nfrom t where b = 1")
        XCTAssertTrue(out.contains("-- note\nFROM"), out)
    }

    func testBlockCommentsAndStringsSurvive() {
        let src = "select 'a -- not comment', E'x\\'y', $$ body $$, /* keep; me */ b from t"
        let out = SQLFormatter.format(src)
        XCTAssertTrue(out.contains("'a -- not comment'"), out)
        XCTAssertTrue(out.contains("E'x\\'y'"), out)
        XCTAssertTrue(out.contains("$$ body $$"), out)
        XCTAssertTrue(out.contains("/* keep; me */"), out)
    }

    func testParametersNotSplit() {
        XCTAssertTrue(SQLFormatter.format("select * from t where id = $1").contains("= $1"))
    }

    func testCRLFComment() {
        let out = SQLFormatter.format("SELECT a, -- c\r\n b FROM t")
        XCTAssertFalse(out.contains("-- c b"), out)
    }
}
