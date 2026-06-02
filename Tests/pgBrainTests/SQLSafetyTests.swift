import XCTest
@testable import pgBrain

/// Pure, no-DB coverage of the production guardrail classifier and its
/// quote/comment-aware lexer.
final class SQLSafetyTests: XCTestCase {

    // MARK: classify — verdicts

    func testReadOnlyStarters() {
        for sql in ["SELECT 1", "  select * from t", "SHOW search_path",
                    "EXPLAIN SELECT 1", "VALUES (1),(2)", "TABLE users",
                    "WITH x AS (SELECT 1) SELECT * FROM x"] {
            XCTAssertEqual(SQLSafety.classify(sql), .readOnly, "\(sql)")
        }
    }

    func testEmptyAndWhitespaceIsReadOnly() {
        XCTAssertEqual(SQLSafety.classify(""), .readOnly)
        XCTAssertEqual(SQLSafety.classify("   \n  "), .readOnly)
        XCTAssertEqual(SQLSafety.classify("-- just a comment"), .readOnly)
    }

    func testInsertIsWrite() {
        XCTAssertEqual(SQLSafety.classify("INSERT INTO t VALUES (1)"), .write)
    }

    func testUpdateDeleteScopedVsUnscoped() {
        XCTAssertEqual(SQLSafety.classify("UPDATE t SET x = 1 WHERE id = 5"), .write)
        XCTAssertEqual(SQLSafety.classify("UPDATE t SET x = 1"), .destructiveUnscoped)
        XCTAssertEqual(SQLSafety.classify("DELETE FROM t WHERE id = 5"), .write)
        XCTAssertEqual(SQLSafety.classify("DELETE FROM t"), .destructiveUnscoped)
    }

    func testDeleteWithSubqueryWhereCountsAsScoped() {
        XCTAssertEqual(
            SQLSafety.classify("DELETE FROM t WHERE id IN (SELECT id FROM other)"),
            .write)
    }

    func testTruncateIsDestructive() {
        XCTAssertEqual(SQLSafety.classify("TRUNCATE t"), .destructiveUnscoped)
    }

    func testDDLStarters() {
        for sql in ["DROP TABLE t", "ALTER TABLE t ADD c int", "GRANT SELECT ON t TO u",
                    "REVOKE SELECT ON t FROM u", "VACUUM ANALYZE", "REINDEX TABLE t",
                    "CREATE TABLE t (id int)"] {
            XCTAssertEqual(SQLSafety.classify(sql), .ddl, "\(sql)")
        }
    }

    func testUnknownVerbDefaultsToWrite() {
        // Unrecognised leading keyword (e.g. CALL, a transaction verb) is treated
        // as a write so it isn't silently waved through as read-only.
        XCTAssertEqual(SQLSafety.classify("CALL do_thing()"), .write)
    }

    // MARK: classify — CTE that ends in a mutation

    func testWithEndingInDeletePeeksThrough() {
        XCTAssertEqual(
            SQLSafety.classify("WITH x AS (SELECT 1) DELETE FROM t WHERE id = 1"),
            .write)
        XCTAssertEqual(
            SQLSafety.classify("WITH x AS (SELECT 1) DELETE FROM t"),
            .destructiveUnscoped)
    }

    func testSelectContainingUpdateKeywordInCTE() {
        // The CTE's UPDATE has no WHERE → it rewrites every row, so the guardrail
        // correctly flags the whole statement as an unscoped mutation.
        XCTAssertEqual(
            SQLSafety.classify("WITH d AS (UPDATE t SET x=1 RETURNING *) SELECT * FROM d"),
            .destructiveUnscoped)
        // Add a WHERE inside the CTE and it relaxes to a scoped write.
        XCTAssertEqual(
            SQLSafety.classify("WITH d AS (UPDATE t SET x=1 WHERE id=1 RETURNING *) SELECT * FROM d"),
            .write)
    }

    // MARK: lexer is quote / comment aware

    func testKeywordsInsideStringLiteralAreIgnored() {
        // 'delete' here is data, not a verb — must stay read-only.
        XCTAssertEqual(SQLSafety.classify("SELECT 'please delete this' AS note"), .readOnly)
    }

    func testKeywordsInsideLineCommentAreIgnored() {
        XCTAssertEqual(SQLSafety.classify("SELECT 1 -- delete from t\n"), .readOnly)
    }

    func testKeywordsInsideBlockCommentAreIgnored() {
        XCTAssertEqual(SQLSafety.classify("SELECT 1 /* drop table t */"), .readOnly)
    }

    func testKeywordsInsideDollarQuoteAreIgnored() {
        XCTAssertEqual(SQLSafety.classify("SELECT $$ drop table t $$"), .readOnly)
        XCTAssertEqual(SQLSafety.classify("SELECT $tag$ delete from t $tag$"), .readOnly)
    }

    func testEscapedQuoteInsideStringHandled() {
        // '' is an escaped single quote — the string doesn't terminate early.
        XCTAssertEqual(SQLSafety.classify("SELECT 'it''s a delete note'"), .readOnly)
    }

    func testDoubleQuotedIdentifierTokenised() {
        // The quoted identifier becomes its own token; leading verb still wins.
        XCTAssertEqual(SQLSafety.classify("UPDATE \"my table\" SET x = 1 WHERE id = 1"), .write)
    }

    // MARK: tokens() directly

    func testTokensSplitsOnPunctuationAndKeepsAlnum() {
        XCTAssertEqual(SQLSafety.tokens(in: "a_1, b.c(d)"), ["a_1", "b", "c", "d"])
    }

    func testTokensSkipsCommentsAndStrings() {
        XCTAssertEqual(SQLSafety.tokens(in: "x '/literal/' /* c */ y -- z\n w"),
                       ["x", "y", "w"])
    }

    func testTokensUnterminatedDollarQuoteStops() {
        // Opening $tag$ with no closer consumes to end — no crash, no spurious tokens.
        XCTAssertEqual(SQLSafety.tokens(in: "a $t$ unterminated"), ["a"])
    }

    func testTokensDoubleQuotedBody() {
        XCTAssertEqual(SQLSafety.tokens(in: "\"Mixed Ident\" rest"), ["Mixed Ident", "rest"])
    }
}
