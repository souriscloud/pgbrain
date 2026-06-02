import XCTest
@testable import pgBrain

@MainActor
final class SQLCompletionProviderTests: XCTestCase {

    private func col(_ name: String, _ type: String = "integer") -> ColumnNode {
        ColumnNode(name: name, typeName: type, nullable: true, ordinal: 0)
    }

    private func snapshot() -> SchemaSnapshot {
        let users = TableNode(schema: "public", name: "users", kind: .table,
                              columns: [col("id"), col("email", "text"), col("created_at", "timestamp")],
                              primaryKey: ["id"])
        let orders = TableNode(schema: "public", name: "orders", kind: .table,
                               columns: [col("id"), col("user_id"), col("total", "numeric")])
        let report = TableNode(schema: "public", name: "report", kind: .view, columns: [col("n")])
        let add1 = FunctionNode(schema: "public", name: "add", kind: .function, arguments: "(a integer)", returnType: "integer")
        let add2 = FunctionNode(schema: "public", name: "add", kind: .function, arguments: "(a integer, b integer)", returnType: "integer")
        let events = TableNode(schema: "analytics", name: "events", kind: .table, columns: [col("id"), col("name", "text")])
        return SchemaSnapshot(databaseName: "db", schemas: [
            SchemaNode(name: "public", tables: [users, orders, report], functions: [add1, add2]),
            SchemaNode(name: "analytics", tables: [events]),
        ])
    }

    private func len(_ s: String) -> Int { (s as NSString).length }
    private func values(_ items: [CompletionItem]) -> [String] { items.map(\.value) }

    // MARK: - Clause-strip context

    func testClauseWhereOffersColumnsAndKeywords() {
        let s = snapshot()
        let users = s.schemas[0].tables[0]
        let idItems = SQLCompletionProvider.items(for: "id", in: s, context: .clause(table: users, kind: .whereExpr))
        XCTAssertTrue(values(idItems).contains("id"))
        let andItems = SQLCompletionProvider.items(for: "AN", in: s, context: .clause(table: users, kind: .whereExpr))
        XCTAssertTrue(values(andItems).contains("AND"))
    }

    func testClauseOrderByKeywords() {
        let s = snapshot()
        let users = s.schemas[0].tables[0]
        XCTAssertTrue(values(SQLCompletionProvider.items(for: "AS", in: s, context: .clause(table: users, kind: .orderBy))).contains("ASC"))
        // Empty needle in a clause context yields nothing.
        XCTAssertTrue(SQLCompletionProvider.items(for: "", in: s, context: .clause(table: users, kind: .whereExpr)).isEmpty)
    }

    // MARK: - Expression context

    func testExpressionColumnsRankAboveBuiltins() {
        let s = snapshot()
        let cols = [col("amount", "numeric"), col("status", "text")]
        let all = SQLCompletionProvider.items(for: "", in: s, context: .expression(columns: cols))
        XCTAssertFalse(all.isEmpty)
        // Highest-weight (column) candidates come first.
        XCTAssertEqual(all.first?.kind, .column)
        XCTAssertTrue(values(all).contains("amount"))
    }

    func testExpressionFuzzyMatchesBuiltin() {
        let s = snapshot()
        // "gru" is an in-order subsequence of gen_random_uuid(.
        let items = SQLCompletionProvider.items(for: "gru", in: s, context: .expression(columns: []))
        XCTAssertTrue(values(items).contains("gen_random_uuid()"))
    }

    // MARK: - Scratchpad context

    func testScratchpadGeneralOffersQueryKeywords() {
        let s = snapshot()
        let sql = "sel"
        let items = SQLCompletionProvider.items(for: "sel", in: s, context: .scratchpad(fullText: sql, caretIndex: len(sql)))
        XCTAssertTrue(values(items).contains("SELECT"))
    }

    func testScratchpadTableContextAfterFrom() {
        let s = snapshot()
        let sql = "SELECT * FROM us"
        let items = SQLCompletionProvider.items(for: "us", in: s, context: .scratchpad(fullText: sql, caretIndex: len(sql)))
        XCTAssertTrue(values(items).contains("users"))
    }

    func testScratchpadColumnContextPrioritisesInScopeTable() {
        let s = snapshot()
        let sql = "SELECT  FROM users WHERE em"
        let items = SQLCompletionProvider.items(for: "em", in: s, context: .scratchpad(fullText: sql, caretIndex: len(sql)))
        XCTAssertTrue(values(items).contains("email"))
    }

    func testScratchpadOrderByContext() {
        let s = snapshot()
        let sql = "SELECT * FROM users ORDER BY cr"
        let items = SQLCompletionProvider.items(for: "cr", in: s, context: .scratchpad(fullText: sql, caretIndex: len(sql)))
        XCTAssertTrue(values(items).contains("created_at"))
    }

    func testScratchpadAliasQualifierResolvesColumns() {
        let s = snapshot()
        let sql = "SELECT  FROM users u WHERE u.em"
        let items = SQLCompletionProvider.items(for: "em", in: s, context: .scratchpad(fullText: sql, caretIndex: len(sql)))
        XCTAssertEqual(values(items), ["email"], "alias qualifier narrows to that table's columns")
    }

    func testScratchpadEmptyNeedleAfterSchemaQualifier() {
        let s = snapshot()
        let sql = "SELECT * FROM public."
        let items = SQLCompletionProvider.items(for: "", in: s, context: .scratchpad(fullText: sql, caretIndex: len(sql)))
        XCTAssertTrue(values(items).contains("users"))
        XCTAssertTrue(values(items).contains("orders"))
    }

    func testScratchpadEmptyNeedleNoQualifierIsEmpty() {
        let s = snapshot()
        let sql = "SELECT * FROM users "
        XCTAssertTrue(SQLCompletionProvider.items(for: "", in: s, context: .scratchpad(fullText: sql, caretIndex: len(sql))).isEmpty)
    }

    // MARK: - String / comment guard

    func testNoCompletionsInsideStringLiteral() {
        let s = snapshot()
        let sql = "SELECT 'ab"
        XCTAssertTrue(SQLCompletionProvider.items(for: "ab", in: s, context: .scratchpad(fullText: sql, caretIndex: len(sql))).isEmpty)
    }

    func testNoCompletionsInsideLineComment() {
        let s = snapshot()
        let sql = "SELECT id -- co"
        XCTAssertTrue(SQLCompletionProvider.items(for: "co", in: s, context: .scratchpad(fullText: sql, caretIndex: len(sql))).isEmpty)
    }

    func testNoCompletionsInsideBlockComment() {
        let s = snapshot()
        let sql = "SELECT /* ab"
        XCTAssertTrue(SQLCompletionProvider.items(for: "ab", in: s, context: .scratchpad(fullText: sql, caretIndex: len(sql))).isEmpty)
    }

    // MARK: - Ranking + functions

    func testExactMatchRanksFirst() {
        let s = snapshot()
        let sql = "SELECT * FROM users"
        let items = SQLCompletionProvider.items(for: "users", in: s, context: .scratchpad(fullText: sql, caretIndex: len(sql)))
        XCTAssertEqual(items.first?.value, "users", "exact match outranks partials like user_id-bearing names")
    }

    func testFunctionOverloadsDedupBareName() {
        let s = snapshot()
        // General context surfaces functions; the two `add` overloads collapse
        // to a single bare-name candidate (qualified public.add stays separate).
        let items = SQLCompletionProvider.items(for: "add", in: s, context: .scratchpad(fullText: "add", caretIndex: 3))
        XCTAssertEqual(values(items).filter { $0 == "add" }.count, 1)
        XCTAssertTrue(values(items).contains("public.add"))
        let fn = try! XCTUnwrap(items.first { $0.value == "add" })
        XCTAssertEqual(fn.kind, .function)
        XCTAssertEqual(fn.detail, "(a integer) → integer")
    }

    func testScratchpadSchemaQualifierViaScope() {
        let s = snapshot()
        let sql = "SELECT public.us"
        let items = SQLCompletionProvider.items(for: "us", in: s, context: .scratchpad(fullText: sql, caretIndex: len(sql)))
        XCTAssertTrue(values(items).contains("users"), "schema-qualified prefix resolves that schema's tables")
    }

    func testScratchpadTableNameQualifierViaScope() {
        let s = snapshot()
        let before = "SELECT users.em"
        let sql = before + " FROM users"   // caret sits right after `users.em`
        let items = SQLCompletionProvider.items(for: "em", in: s, context: .scratchpad(fullText: sql, caretIndex: len(before)))
        XCTAssertTrue(values(items).contains("email"), "table-name qualifier resolves that table's columns")
    }

    func testScratchpadGeneralOffersDMLKeywords() {
        let s = snapshot()
        let items = SQLCompletionProvider.items(for: "INS", in: s, context: .scratchpad(fullText: "INS", caretIndex: 3))
        XCTAssertTrue(values(items).contains("INSERT INTO"))
    }

    // MARK: - Back-compat string API

    func testCompletionsProjectsValues() {
        let s = snapshot()
        let sql = "SELECT * FROM us"
        let strings = SQLCompletionProvider.completions(for: "us", in: s, context: .scratchpad(fullText: sql, caretIndex: len(sql)))
        XCTAssertTrue(strings.contains("users"))
        XCTAssertEqual(strings, strings.map { $0 })  // is [String]
    }
}
