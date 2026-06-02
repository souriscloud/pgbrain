import XCTest
@testable import pgBrain

// Shared fixture builders for the pure schema-structure types.
private func col(_ name: String, _ type: String = "integer", nullable: Bool = true, ord: Int = 0) -> ColumnNode {
    ColumnNode(name: name, typeName: type, nullable: nullable, ordinal: ord)
}
private func table(_ schema: String, _ name: String, kind: TableNode.Kind = .table,
                   columns: [ColumnNode] = []) -> TableNode {
    TableNode(schema: schema, name: name, kind: kind, columns: columns)
}
private func snapshot(_ schemas: [SchemaNode]) -> SchemaSnapshot {
    SchemaSnapshot(databaseName: "test", schemas: schemas)
}

final class SchemaDiffTests: XCTestCase {

    func testIdenticalSnapshotsDiffEmpty() {
        let s = snapshot([SchemaNode(name: "public", tables: [table("public", "t", columns: [col("id")])])])
        let r = SchemaDiff.diff(left: s, right: s)
        XCTAssertTrue(r.isEmpty)
        XCTAssertTrue(r.addedTables.isEmpty)
        XCTAssertTrue(r.removedTables.isEmpty)
        XCTAssertTrue(r.changedTables.isEmpty)
    }

    func testAddedAndRemovedTables() {
        let left = snapshot([SchemaNode(name: "public", tables: [table("public", "keep"), table("public", "gone")])])
        let right = snapshot([SchemaNode(name: "public", tables: [table("public", "keep"), table("public", "fresh")])])
        let r = SchemaDiff.diff(left: left, right: right)
        XCTAssertFalse(r.isEmpty)
        XCTAssertEqual(r.addedTables.map(\.name), ["fresh"])
        XCTAssertEqual(r.removedTables.map(\.name), ["gone"])
        XCTAssertTrue(r.changedTables.isEmpty)
    }

    func testAddedRemovedTablesSortedByQualifiedName() {
        let left = snapshot([SchemaNode(name: "public", tables: [])])
        let right = snapshot([SchemaNode(name: "public", tables: [
            table("public", "zebra"), table("public", "alpha"), table("public", "mid")
        ])])
        let r = SchemaDiff.diff(left: left, right: right)
        XCTAssertEqual(r.addedTables.map(\.name), ["alpha", "mid", "zebra"])
    }

    func testColumnAddRemoveAndTypeChange() {
        let left = snapshot([SchemaNode(name: "public", tables: [
            table("public", "t", columns: [col("id", "integer"), col("old_col", "text"), col("flag", "boolean", nullable: true)])
        ])])
        let right = snapshot([SchemaNode(name: "public", tables: [
            table("public", "t", columns: [col("id", "bigint"), col("new_col", "text"), col("flag", "boolean", nullable: false)])
        ])])
        let r = SchemaDiff.diff(left: left, right: right)
        XCTAssertEqual(r.changedTables.count, 1)
        let change = r.changedTables[0]
        XCTAssertTrue(change.hasChanges)
        XCTAssertEqual(change.addedColumns.map(\.name), ["new_col"])
        XCTAssertEqual(change.removedColumns.map(\.name), ["old_col"])
        // id changed type, flag changed nullability → both reported, sorted by name.
        XCTAssertEqual(change.changedColumns.map(\.name), ["flag", "id"])
        XCTAssertEqual(change.id, "public.t")

        let idChange = try! XCTUnwrap(change.changedColumns.first { $0.name == "id" })
        XCTAssertEqual(idChange.leftType, "integer")
        XCTAssertEqual(idChange.rightType, "bigint")
        XCTAssertEqual(idChange.id, "id")

        let flagChange = try! XCTUnwrap(change.changedColumns.first { $0.name == "flag" })
        XCTAssertTrue(flagChange.leftNullable)
        XCTAssertFalse(flagChange.rightNullable)
    }

    func testTableWithNoColumnChangesIsNotReportedChanged() {
        let t = table("public", "t", columns: [col("id")])
        let r = SchemaDiff.diff(left: snapshot([SchemaNode(name: "public", tables: [t])]),
                                right: snapshot([SchemaNode(name: "public", tables: [t])]))
        XCTAssertTrue(r.changedTables.isEmpty)
    }
}

final class SchemaIndexTests: XCTestCase {

    private func index() -> SchemaIndex {
        SchemaIndex(snapshot: snapshot([
            SchemaNode(name: "public", tables: [table("public", "customers"), table("public", "orders")]),
            SchemaNode(name: "sales", tables: [table("sales", "order_items")])
        ]))
    }

    func testTotalsAndLookup() {
        let idx = index()
        XCTAssertEqual(idx.totalTables, 3)
        XCTAssertEqual(idx.tablesByID.count, 3)
        XCTAssertNotNil(idx.tablesByID["public.customers"])
    }

    func testSubstringMatchIsCaseInsensitive() {
        let idx = index()
        // "order" is a substring of public.orders and sales.order_items.
        XCTAssertEqual(idx.matches("order").map(\.qualifiedName), ["public.orders", "sales.order_items"])
        // Case-insensitive.
        XCTAssertEqual(Set(idx.matches("ORDER").map(\.qualifiedName)),
                       Set(["public.orders", "sales.order_items"]))
    }

    func testMatchesOnSchemaQualifier() {
        let idx = index()
        // The schema name is part of the searchable string.
        XCTAssertEqual(idx.matches("sales.").map(\.qualifiedName), ["sales.order_items"])
    }

    func testEmptyTermAndNoMatchReturnEmpty() {
        let idx = index()
        XCTAssertTrue(idx.matches("").isEmpty)
        XCTAssertTrue(idx.matches("zzzznope").isEmpty)
    }

    func testResultsSortedByQualifiedName() {
        let idx = SchemaIndex(snapshot: snapshot([
            SchemaNode(name: "public", tables: [table("public", "ab_z"), table("public", "ab_a"), table("public", "ab_m")])
        ]))
        XCTAssertEqual(idx.matches("ab_").map(\.qualifiedName), ["public.ab_a", "public.ab_m", "public.ab_z"])
    }
}
