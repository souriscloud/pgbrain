import XCTest
@testable import pgBrain

final class ScratchpadParametersTests: XCTestCase {

    // MARK: names

    func testNamesDistinctInOrder() {
        let sql = "SELECT * FROM t WHERE id = :id AND owner = :owner OR id = :id"
        XCTAssertEqual(ScratchpadParameters.names(in: sql), ["id", "owner"])
    }

    func testNamesIgnoresCastOperator() {
        // `::int` and `::text` are casts, not parameters.
        XCTAssertEqual(ScratchpadParameters.names(in: "SELECT x::int, y::text FROM t"), [])
        // A param next to a cast still resolves.
        XCTAssertEqual(ScratchpadParameters.names(in: "WHERE a = :a::int"), ["a"])
    }

    func testNamesIgnoresStringsAndComments() {
        XCTAssertEqual(ScratchpadParameters.names(in: "SELECT ':notparam' AS x"), [])
        XCTAssertEqual(ScratchpadParameters.names(in: "SELECT 1 -- :nope\nWHERE a = :a"), ["a"])
        XCTAssertEqual(ScratchpadParameters.names(in: "SELECT /* :nope */ :real"), ["real"])
        // '' escape inside a string keeps us in-string across the quote pair.
        XCTAssertEqual(ScratchpadParameters.names(in: "SELECT 'it''s :nope' , :yes"), ["yes"])
    }

    func testNamesIgnoresDollarQuotedBody() {
        let sql = "CREATE FUNCTION f() RETURNS int LANGUAGE sql AS $$ SELECT :nope $$; SELECT :yes"
        XCTAssertEqual(ScratchpadParameters.names(in: sql), ["yes"])
        let tagged = "AS $body$ :nope $body$ , :yes"
        XCTAssertEqual(ScratchpadParameters.names(in: tagged), ["yes"])
    }

    func testLoneColonIsNotAParameter() {
        XCTAssertEqual(ScratchpadParameters.names(in: "SELECT 1 : 2"), [])
        XCTAssertEqual(ScratchpadParameters.names(in: "SELECT a:"), [])
    }

    // MARK: substitute

    func testSubstituteReplacesAllOccurrences() {
        let out = ScratchpadParameters.substitute(
            "SELECT * FROM t WHERE id = :id AND parent = :id",
            with: ["id": "42"])
        XCTAssertEqual(out, "SELECT * FROM t WHERE id = 42 AND parent = 42")
    }

    func testSubstituteMixedNamesAndRawSQLValues() {
        let out = ScratchpadParameters.substitute(
            "WHERE name = :name AND created > :since",
            with: ["name": "'O''Brien'", "since": "now() - interval '1 day'"])
        XCTAssertEqual(out, "WHERE name = 'O''Brien' AND created > now() - interval '1 day'")
    }

    func testSubstituteLeavesUnmappedNamesUntouched() {
        let out = ScratchpadParameters.substitute("WHERE a = :a AND b = :b", with: ["a": "1"])
        XCTAssertEqual(out, "WHERE a = 1 AND b = :b")
    }

    func testSubstituteNeverTouchesCastsStringsOrComments() {
        let sql = "SELECT x::int, ':a' /* :a */ -- :a\nWHERE a = :a"
        let out = ScratchpadParameters.substitute(sql, with: ["a": "99"])
        XCTAssertEqual(out, "SELECT x::int, ':a' /* :a */ -- :a\nWHERE a = 99")
    }

    func testSubstituteNoOpWhenNoParameters() {
        let sql = "SELECT 1::int FROM t"
        XCTAssertEqual(ScratchpadParameters.substitute(sql, with: ["x": "1"]), sql)
    }
}
