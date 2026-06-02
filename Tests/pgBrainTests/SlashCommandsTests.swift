import XCTest
@testable import pgBrain

/// Pure coverage of the psql-style slash-command translator.
final class SlashCommandsTests: XCTestCase {

    func testNonSlashInputPassesThrough() {
        XCTAssertEqual(SlashCommands.translate("SELECT 1"), "SELECT 1")
        XCTAssertEqual(SlashCommands.translate("   not a command "), "   not a command ")
    }

    func testUnknownCommandPassesThrough() {
        XCTAssertEqual(SlashCommands.translate("\\zzz"), "\\zzz")
    }

    func testDatabaseAndNamespaceAndRoleListings() {
        XCTAssertTrue(SlashCommands.translate("\\l").contains("pg_database"))
        XCTAssertTrue(SlashCommands.translate("\\list").contains("pg_database"))
        XCTAssertTrue(SlashCommands.translate("\\dn").contains("pg_namespace"))
        XCTAssertTrue(SlashCommands.translate("\\du").contains("pg_roles"))
        XCTAssertTrue(SlashCommands.translate("\\di").contains("pg_index"))
        XCTAssertTrue(SlashCommands.translate("\\ds").contains("pg_sequences"))
        XCTAssertTrue(SlashCommands.translate("\\df").contains("pg_get_function_result"))
        XCTAssertTrue(SlashCommands.translate("\\dx").contains("pg_extension"))
    }

    func testRelationListingsByKind() {
        XCTAssertTrue(SlashCommands.translate("\\dt").contains("'r','p'"))
        XCTAssertTrue(SlashCommands.translate("\\dv").contains("'v'"))
        XCTAssertTrue(SlashCommands.translate("\\dm").contains("'m'"))
    }

    func testRelationListingUnfilteredExcludesCatalog() {
        let sql = SlashCommands.translate("\\dt")
        XCTAssertTrue(sql.contains("NOT IN ('pg_catalog','information_schema')"))
    }

    func testRelationListingWithBareNameFilterUsesIlike() {
        let sql = SlashCommands.translate("\\dt users")
        XCTAssertTrue(sql.contains("c.relname ILIKE 'users'"))
    }

    func testRelationListingWithSchemaQualifiedFilter() {
        let sql = SlashCommands.translate("\\dt public.users")
        XCTAssertTrue(sql.contains("n.nspname = 'public'"))
        XCTAssertTrue(sql.contains("c.relname ILIKE 'users'"))
    }

    func testFilterSingleQuoteIsEscaped() {
        let sql = SlashCommands.translate("\\dt o'brien")
        XCTAssertTrue(sql.contains("ILIKE 'o''brien'"), sql)
    }

    func testDescribeNamedRelation() {
        let sql = SlashCommands.translate("\\d my_table")
        XCTAssertTrue(sql.contains("format_type"))
        XCTAssertTrue(sql.contains("'my_table'::regclass"))
    }

    func testDescribePlusBehavesLikeDescribe() {
        XCTAssertTrue(SlashCommands.translate("\\d+ my_table").contains("'my_table'::regclass"))
    }

    func testBareDescribeListsAllRelationKinds() {
        let sql = SlashCommands.translate("\\d")
        XCTAssertTrue(sql.contains("'r','p','v','m','S'"))
    }

    func testTranslateCellMixesSlashAndSQL() {
        // Each \-line expands to a multi-line catalog query, so assert by content
        // rather than line position; the plain SQL line must survive verbatim.
        let cell = "\\dt\nSELECT 1;\n  \\dn  "
        let out = SlashCommands.translateCell(cell)
        XCTAssertTrue(out.contains("pg_class"))       // \dt expanded
        XCTAssertTrue(out.contains("\nSELECT 1;\n"))  // untouched, in place
        XCTAssertTrue(out.contains("pg_namespace"))   // \dn expanded
    }
}
