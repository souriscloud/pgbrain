import XCTest
@testable import pgBrain

final class SchemaModelTests: XCTestCase {

    private func snapshot() -> SchemaSnapshot {
        SchemaSnapshot(databaseName: "db", schemas: [
            SchemaNode(name: "public", tables: [
                TableNode(schema: "public", name: "t1", kind: .table, columns: []),
                TableNode(schema: "public", name: "t2", kind: .table, columns: []),
            ])
        ])
    }

    func testEmptySnapshot() {
        XCTAssertEqual(SchemaSnapshot.empty.databaseName, "")
        XCTAssertTrue(SchemaSnapshot.empty.schemas.isEmpty)
    }

    func testMergingColumnsFoldsOnlyMatchingTables() {
        let cols: SchemaSnapshot.ColumnMap = [
            "public\u{1F}t1": [ColumnNode(name: "id", typeName: "integer", nullable: false, ordinal: 0)]
        ]
        let merged = snapshot().merging(columns: cols)
        XCTAssertEqual(merged.schemas[0].tables[0].columns.map(\.name), ["id"])  // t1 filled
        XCTAssertTrue(merged.schemas[0].tables[1].columns.isEmpty)               // t2 untouched
    }

    func testMergingColumnsForSpecificTableHitAndMiss() {
        let cols = [ColumnNode(name: "x", typeName: "text", nullable: true, ordinal: 0)]
        let hit = snapshot().mergingColumns(forSchema: "public", table: "t2", columns: cols)
        XCTAssertEqual(hit.schemas[0].tables[1].columns.map(\.name), ["x"])

        // Unknown schema/table leaves the snapshot unchanged.
        let miss = snapshot().mergingColumns(forSchema: "nope", table: "t2", columns: cols)
        XCTAssertEqual(miss, snapshot())
        let miss2 = snapshot().mergingColumns(forSchema: "public", table: "ghost", columns: cols)
        XCTAssertEqual(miss2, snapshot())
    }

    func testTableNodeEditabilityAndPkColumns() {
        var t = TableNode(schema: "s", name: "t", kind: .table, columns: [
            ColumnNode(name: "a", typeName: "int", nullable: false, ordinal: 0),
            ColumnNode(name: "b", typeName: "int", nullable: false, ordinal: 1),
        ], primaryKey: ["b", "a"])
        XCTAssertTrue(t.isEditable)
        XCTAssertEqual(t.primaryKeyColumns.map(\.name), ["b", "a"])   // PK order preserved
        XCTAssertEqual(t.qualifiedName, "s.t")
        XCTAssertEqual(t.id, "s.t")

        t.primaryKey = []
        XCTAssertFalse(t.isEditable, "no PK ⇒ not editable")
        var view = t; view.kind = .view; view.primaryKey = ["a"]
        XCTAssertFalse(view.isEditable, "views aren't editable even with a key")
    }

    func testFunctionNodeSignatures() {
        let f = FunctionNode(schema: "app", name: "calc", kind: .function,
                             arguments: "(integer, text)", returnType: "integer")
        XCTAssertEqual(f.signature, "calc(integer, text)")
        XCTAssertEqual(f.qualifiedSignature, "app.calc(integer, text)")
        XCTAssertEqual(f.id, "app.calc((integer, text))")
    }

    func testColumnTypeKindBuckets() {
        let cases: [(String, ColumnTypeKind)] = [
            ("character varying(255)", .text), ("text", .text), ("name", .text), ("varchar", .text),
            ("smallint", .integer), ("integer", .integer), ("bigint", .integer),
            ("int2", .integer), ("int4", .integer), ("int8", .integer), ("oid", .integer),
            ("real", .number), ("double precision", .number), ("numeric(10,2)", .number), ("money", .number),
            ("boolean", .bool),
            ("timestamp with time zone", .timestamp), ("timestamp", .timestamp),
            ("date", .date), ("time", .date), ("time without time zone", .date),
            ("json", .json), ("jsonb", .json),
            ("uuid", .uuid),
            ("bytea", .bytes),
            ("inet", .unknown), ("some_enum", .unknown),
        ]
        for (typeName, expected) in cases {
            XCTAssertEqual(ColumnTypeKind.from(typeName: typeName), expected, typeName)
        }
    }
}
