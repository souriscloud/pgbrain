import XCTest
import SwiftUI
@testable import pgBrain

final class SQLIdentTests: XCTestCase {
    func testQuoteWrapsInDoubleQuotes() {
        XCTAssertEqual(SQLIdent.quote("users"), "\"users\"")
    }

    func testQuoteDoublesEmbeddedQuotes() {
        XCTAssertEqual(SQLIdent.quote("we\"ird"), "\"we\"\"ird\"")
    }

    func testQualifiedJoinsSchemaAndName() {
        XCTAssertEqual(SQLIdent.qualified(schema: "s", name: "t"), "\"s\".\"t\"")
    }
}

@MainActor
final class ConnectionAppearanceTests: XCTestCase {
    private func appearance(prod: Bool = false, tag: Connection.ColorTag = .none) -> ConnectionAppearance {
        var c = Connection(name: "X")
        c.isProduction = prod
        c.colorTag = tag
        return ConnectionAppearance(connection: c)
    }

    func testAccentDefaultsToBrandWhenNoTag() {
        XCTAssertEqual(appearance(tag: .none).accent, Tokens.Brand.primary)
    }

    func testAccentUsesColorTagWhenSet() {
        XCTAssertEqual(appearance(tag: .blue).accent, Connection.ColorTag.blue.swiftUIColor)
    }

    func testEmphasizedIsDangerForProductionElseAccent() {
        XCTAssertEqual(appearance(prod: true).emphasized, Tokens.Brand.danger)
        XCTAssertEqual(appearance(prod: false, tag: .green).emphasized,
                       Connection.ColorTag.green.swiftUIColor)
    }

    func testWindowTintProductionThenTagThenNil() {
        XCTAssertNotNil(appearance(prod: true).windowTintNS)        // prod wash
        XCTAssertNotNil(appearance(tag: .orange).windowTintNS)      // tag wash
        XCTAssertNil(appearance(tag: .none).windowTintNS)           // plain
    }

    func testSuffixMarksProduction() {
        XCTAssertEqual(appearance(prod: true).suffix, " · PROD")
        XCTAssertEqual(appearance(prod: false).suffix, "")
    }
}
