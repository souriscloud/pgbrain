import XCTest
@testable import pgBrain

// MARK: - SQLTokenizer

final class SQLTokenizerTests: XCTestCase {
    private func kinds(_ s: String) -> [SQLToken.Kind] { SQLTokenizer.tokenize(s).map(\.kind) }

    func testKeywordsAreLowercasedAndRecognised() {
        XCTAssertEqual(kinds("SELECT"), [.keyword("select")])
        XCTAssertEqual(kinds("Select fRoM"), [.keyword("select"), .keyword("from")])
    }

    func testIdentifiersAndQuotedIdentifiers() {
        XCTAssertEqual(kinds("foo_bar1"), [.identifier("foo_bar1")])
        // "" is an escaped quote inside a quoted identifier.
        XCTAssertEqual(kinds("\"a\"\"b\""), [.quotedIdent("a\"b")])
        // A non-keyword word stays an identifier even if PG reserves it elsewhere.
        XCTAssertEqual(kinds("count"), [.identifier("count")])
    }

    func testStringsAndDollarQuotes() {
        XCTAssertEqual(kinds("'it''s'"), [.string])
        XCTAssertEqual(kinds("$$body$$"), [.string])
        XCTAssertEqual(kinds("$tag$x;y$tag$"), [.string])
        // Unterminated string runs to end → still one token.
        XCTAssertEqual(kinds("'open"), [.string])
        // `$1` is not a dollar-quote → falls through ($ op + number).
        XCTAssertEqual(SQLTokenizer.tokenize("$1").count, 2)
    }

    func testComments() {
        XCTAssertEqual(kinds("SELECT -- hi\nx"), [.keyword("select"), .comment, .identifier("x")])
        XCTAssertEqual(kinds("/* c */ x"), [.comment, .identifier("x")])
        // Unterminated block comment runs to end.
        XCTAssertEqual(kinds("/* open"), [.comment])
    }

    func testNumbers() {
        XCTAssertEqual(kinds("123"), [.number])
        XCTAssertEqual(kinds("1.5"), [.number])
        XCTAssertEqual(kinds("1e5"), [.number])
        XCTAssertEqual(kinds("1.5E-3"), [.number])
    }

    func testOperatorsAndPunctuation() {
        XCTAssertEqual(kinds("::"), [.op("::")])
        XCTAssertEqual(kinds("<>"), [.op("<>")])
        XCTAssertEqual(kinds("<="), [.op("<=")])
        XCTAssertEqual(kinds(">="), [.op(">=")])
        XCTAssertEqual(kinds("!="), [.op("!=")])
        XCTAssertEqual(kinds("||"), [.op("||")])
        XCTAssertEqual(kinds("+"), [.op("+")])
        XCTAssertEqual(kinds(".,;()"), [.punct("."), .punct(","), .punct(";"), .punct("("), .punct(")")])
    }

    func testRealisticStatementTokenStream() {
        let ks = kinds("SELECT a, 1 FROM t WHERE a <= 2")
        XCTAssertEqual(ks, [
            .keyword("select"), .identifier("a"), .punct(","), .number,
            .keyword("from"), .identifier("t"),
            .keyword("where"), .identifier("a"), .op("<="), .number,
        ])
    }
}

// MARK: - SQLScope

@MainActor
final class SQLScopeTests: XCTestCase {
    private func len(_ s: String) -> Int { (s as NSString).length }

    func testFromReferencesWithAlias() {
        let sql = "SELECT id FROM users u WHERE "
        let a = SQLScope.analyze(text: sql, caretIndex: len(sql))
        XCTAssertEqual(a.references, [SQLScope.TableRef(schema: nil, table: "users", alias: "u")])
        XCTAssertEqual(a.context, .column, "after WHERE → column context")
        XCTAssertNil(a.qualifier)
    }

    func testSchemaQualifiedAndJoinAndAsAlias() {
        let sql = "SELECT * FROM public.orders o JOIN items AS i ON o.id = i.oid"
        let a = SQLScope.analyze(text: sql, caretIndex: len(sql))
        XCTAssertTrue(a.references.contains(SQLScope.TableRef(schema: "public", table: "orders", alias: "o")))
        XCTAssertTrue(a.references.contains(SQLScope.TableRef(schema: nil, table: "items", alias: "i")))
        XCTAssertEqual(a.context, .column, "after ON → column context")
    }

    func testTableContextAfterFrom() {
        let sql = "SELECT * FROM "
        XCTAssertEqual(SQLScope.analyze(text: sql, caretIndex: len(sql)).context, .table)
    }

    func testOrderByContext() {
        let sql = "SELECT * FROM t ORDER BY "
        XCTAssertEqual(SQLScope.analyze(text: sql, caretIndex: len(sql)).context, .orderBy)
    }

    func testGeneralContextWhenNoClauseKeyword() {
        let sql = "1 + "
        let a = SQLScope.analyze(text: sql, caretIndex: len(sql))
        XCTAssertEqual(a.context, .general)
        XCTAssertTrue(a.references.isEmpty)
    }

    func testTrailingQualifier() {
        let sql = "SELECT * FROM users u WHERE u."
        XCTAssertEqual(SQLScope.analyze(text: sql, caretIndex: len(sql)).qualifier, "u")
        // Partial after the dot still resolves the qualifier.
        let sql2 = "SELECT * FROM users u WHERE u.na"
        XCTAssertEqual(SQLScope.analyze(text: sql2, caretIndex: len(sql2)).qualifier, "u")
    }

    func testStatementSlicingIsolatesCaretStatement() {
        let sql = "SELECT 1 FROM t1; SELECT * FROM t2 WHERE "
        let a = SQLScope.analyze(text: sql, caretIndex: len(sql))
        XCTAssertEqual(a.references, [SQLScope.TableRef(schema: nil, table: "t2", alias: nil)])
    }

    func testCommaSeparatedTables() {
        let sql = "SELECT * FROM a, b WHERE "
        let a = SQLScope.analyze(text: sql, caretIndex: len(sql))
        XCTAssertEqual(a.references.map(\.table), ["a", "b"])
    }
}

// MARK: - SQLFormatter

@MainActor
final class SQLFormatterTests: XCTestCase {
    func testClauseKeywordsGetOwnLineAndUppercase() {
        let out = SQLFormatter.format("select * from users where id = 1 order by created_at desc")
        XCTAssertTrue(out.contains("SELECT "))
        XCTAssertTrue(out.contains("\nFROM "))
        XCTAssertTrue(out.contains("\nWHERE "))
        XCTAssertTrue(out.contains("\nORDER BY "))
        XCTAssertTrue(out.hasSuffix("\n"))
    }

    func testMultiWordJoin() {
        XCTAssertTrue(SQLFormatter.format("select * from a left join b on a.id = b.id").contains("LEFT JOIN"))
    }

    func testSelectListCommasBreakLines() {
        let out = SQLFormatter.format("select a, b, c from t")
        XCTAssertTrue(out.contains(",\n  "), "top-level projection commas indent onto new lines")
    }

    func testFunctionArgCommasStayInline() {
        // The comma inside the parens stays inline (", ") rather than breaking
        // onto an indented new line the way a top-level projection comma would.
        let out = SQLFormatter.format("select coalesce(a, b) from t")
        XCTAssertTrue(out.contains("a, b"))
        XCTAssertFalse(out.contains("a,\n"), "function-arg comma must not break the line")
    }

    func testAndOrIndented() {
        XCTAssertTrue(SQLFormatter.format("select * from t where a and b").contains("\n  AND"))
    }

    func testWhitespaceOnlyInputReturnedVerbatim() {
        XCTAssertEqual(SQLFormatter.format("   "), "   ")
    }
}

// MARK: - JSONFormatter

final class JSONFormatterTests: XCTestCase {
    func testPrettyAndCompact() {
        let pretty = JSONFormatter.pretty("{\"a\":1}")
        XCTAssertNotNil(pretty)
        XCTAssertTrue(pretty!.contains("\n"))
        XCTAssertEqual(JSONFormatter.compact("{ \"a\" : 1 }"), "{\"a\":1}")
    }

    func testFragmentsAllowed() {
        XCTAssertEqual(JSONFormatter.pretty("42"), "42")
        XCTAssertTrue(JSONFormatter.isValid("true"))
        XCTAssertTrue(JSONFormatter.isValid("\"a string\""))
    }

    func testInvalidInputs() {
        XCTAssertNil(JSONFormatter.pretty("{bad"))
        XCTAssertNil(JSONFormatter.compact("nope"))
        XCTAssertFalse(JSONFormatter.isValid(""))
        XCTAssertFalse(JSONFormatter.isValid("   "))
    }
}

// MARK: - SQLHoverResolver

@MainActor
final class SQLHoverResolverTests: XCTestCase {
    private func snapshot() -> SchemaSnapshot {
        let users = TableNode(schema: "public", name: "users", kind: .table,
                              columns: [ColumnNode(name: "id", typeName: "integer", nullable: false, ordinal: 1),
                                        ColumnNode(name: "email", typeName: "text", nullable: true, ordinal: 2)],
                              primaryKey: ["id"])
        let v = TableNode(schema: "public", name: "active_users", kind: .view,
                          columns: [ColumnNode(name: "id", typeName: "integer", nullable: true, ordinal: 1)])
        let solo = TableNode(schema: "solo", name: "only", kind: .table,
                             columns: [ColumnNode(name: "x", typeName: "int", nullable: true, ordinal: 1)])
        let fn = FunctionNode(schema: "public", name: "add", kind: .function,
                              arguments: "(a integer, b integer)", returnType: "integer")
        let proc = FunctionNode(schema: "public", name: "do_it", kind: .procedure,
                                arguments: "()", returnType: "")
        return SchemaSnapshot(databaseName: "db", schemas: [
            SchemaNode(name: "public", tables: [users, v], functions: [fn, proc]),
            SchemaNode(name: "solo", tables: [solo]),
        ])
    }

    func testSchemaMatchPluralAndSingular() {
        let s = snapshot()
        XCTAssertEqual(SQLHoverResolver.describe(identifier: "public", in: s), "public · 2 tables")
        XCTAssertEqual(SQLHoverResolver.describe(identifier: "solo", in: s), "solo · 1 table")
    }

    func testTableMatchWithPKAndViewTag() {
        let s = snapshot()
        let users = try! XCTUnwrap(SQLHoverResolver.describe(identifier: "users", in: s))
        XCTAssertTrue(users.contains("public.users"))
        XCTAssertTrue(users.contains("2 columns"))
        XCTAssertTrue(users.contains("PK: id"))
        XCTAssertTrue(SQLHoverResolver.describe(identifier: "active_users", in: s)!.contains("view"))
    }

    func testColumnMatchCollatesAcrossTables() {
        let s = snapshot()
        let id = try! XCTUnwrap(SQLHoverResolver.describe(identifier: "id", in: s))
        XCTAssertTrue(id.contains("public.users.id"))
        XCTAssertTrue(id.contains("integer"))
        XCTAssertTrue(id.contains("NOT NULL"), "users.id is NOT NULL")
    }

    func testFunctionMatchTags() {
        let s = snapshot()
        XCTAssertTrue(SQLHoverResolver.describe(identifier: "add", in: s)!.contains("[fn]"))
        XCTAssertTrue(SQLHoverResolver.describe(identifier: "add", in: s)!.contains("→ integer"))
        XCTAssertTrue(SQLHoverResolver.describe(identifier: "do_it", in: s)!.contains("[procedure]"))
    }

    func testNoMatchReturnsNil() {
        XCTAssertNil(SQLHoverResolver.describe(identifier: "nonexistent", in: snapshot()))
    }

    func testColumnHitsCappedAtFive() {
        // Six tables each with a 'shared' column → "… +1 more".
        let tables = (0..<6).map { i in
            TableNode(schema: "public", name: "t\(i)", kind: .table,
                      columns: [ColumnNode(name: "shared", typeName: "int", nullable: true, ordinal: 1)])
        }
        let s = SchemaSnapshot(databaseName: "db", schemas: [SchemaNode(name: "public", tables: tables)])
        let out = try! XCTUnwrap(SQLHoverResolver.describe(identifier: "shared", in: s))
        XCTAssertTrue(out.contains("… +1 more"))
        XCTAssertEqual(out.components(separatedBy: "\n").count, 6, "5 hits + the overflow line")
    }
}

// MARK: - CompletionItem

final class CompletionItemTests: XCTestCase {
    func testInitDefaultsLabelToValue() {
        let c = CompletionItem(value: "users", kind: .table)
        XCTAssertEqual(c.label, "users")
        XCTAssertNil(c.detail)
        XCTAssertEqual(c.id, "users\u{1F}")
    }

    func testInitWithLabelAndDetail() {
        let c = CompletionItem(value: "count(", label: "count", detail: "aggregate", kind: .function)
        XCTAssertEqual(c.value, "count(")
        XCTAssertEqual(c.label, "count")
        XCTAssertEqual(c.detail, "aggregate")
        XCTAssertEqual(c.id, "count(\u{1F}aggregate")
    }

    func testEveryKindHasSymbolCategoryAndTint() {
        let kinds: [CompletionItem.Kind] = [.column, .table, .view, .schema, .function, .keyword, .enumValue, .snippet]
        for k in kinds {
            XCTAssertFalse(k.symbol.isEmpty)
            XCTAssertFalse(k.categoryLabel.isEmpty)
            _ = k.tint   // execute the tint mapping
        }
        XCTAssertEqual(CompletionItem.Kind.enumValue.categoryLabel, "enum")
    }
}
