import XCTest
import PostgresNIO
@testable import pgBrain

final class CrossDBCopyTests: XCTestCase {

    private func col(_ name: String, _ type: String = "integer") -> ColumnNode {
        ColumnNode(name: name, typeName: type, nullable: true, ordinal: 0)
    }
    private func map(_ source: String, _ type: String, to target: String) -> CrossDBCopy.Mapping {
        CrossDBCopy.Mapping(sourceColumn: col(source, type), targetColumnName: target)
    }

    // MARK: - pure builders

    func testStrategyMetadata() {
        XCTAssertEqual(CrossDBCopy.Strategy.allCases.count, 3)
        XCTAssertTrue(CrossDBCopy.Strategy.upsert.needsConflictColumns)
        XCTAssertFalse(CrossDBCopy.Strategy.append.needsConflictColumns)
        for s in CrossDBCopy.Strategy.allCases { XCTAssertFalse(s.uiLabel.isEmpty) }
    }

    func testCreateTableSQLUsesSourceTypesAndTargetNames() {
        let sql = CrossDBCopy.createTableSQL(schema: "dst", table: "t", mappings: [
            map("id", "integer", to: "id"),
            map("name", "text", to: "full_name"),
        ])
        XCTAssertEqual(sql, "CREATE TABLE IF NOT EXISTS \"dst\".\"t\" (\"id\" integer, \"full_name\" text)")
    }

    func testUpsertSQLUpdatesNonKeyColumns() {
        let sql = CrossDBCopy.upsertSQL(fromTemp: "_tmp", schema: "s", table: "t",
                                        targetColumns: ["id", "a", "b"], conflictColumns: ["id"])
        XCTAssertEqual(sql,
            "INSERT INTO \"s\".\"t\" (\"id\", \"a\", \"b\") SELECT \"id\", \"a\", \"b\" FROM \"_tmp\" "
            + "ON CONFLICT (\"id\") DO UPDATE SET \"a\" = EXCLUDED.\"a\", \"b\" = EXCLUDED.\"b\"")
    }

    func testUpsertSQLDegradesToDoNothingWhenAllColumnsAreKeys() {
        let sql = CrossDBCopy.upsertSQL(fromTemp: "_tmp", schema: "s", table: "t",
                                        targetColumns: ["a", "b"], conflictColumns: ["a", "b"])
        XCTAssertTrue(sql.hasSuffix("ON CONFLICT (\"a\", \"b\") DO NOTHING"))
    }

    // MARK: - E2E (source + target are two schemas in the same DB)

    func testAutoCreateThenCopy() async throws {
        let db = try await TestDB.connectOrSkip(); defer { db.shutdown() }
        let s = TestDB.uniqueTag(); let t = TestDB.uniqueTag()
        await db.dropSchemas(s, t)
        do {
            try await db.exec("""
            CREATE SCHEMA "\(s)"; CREATE SCHEMA "\(t)";
            CREATE TABLE "\(s)".src (id int PRIMARY KEY, v text);
            INSERT INTO "\(s)".src VALUES (1,'a'),(2,'b');
            """)
            let srcNode = TableNode(schema: s, name: "src", kind: .table,
                                    columns: [col("id"), col("v", "text")], primaryKey: ["id"])
            let plan = CrossDBCopy.Plan(
                source: srcNode, sourceClient: db.client, target: .existing(db.client),
                targetSchema: t, targetTable: "dst", strategy: .append,
                mappings: [map("id", "integer", to: "id"), map("v", "text", to: "v")],
                autoCreate: true)
            let stats = try await CrossDBCopy.execute(plan: plan)
            XCTAssertEqual(stats.rowsCopied, 2)
            let exists = try await db.scalarBool("SELECT EXISTS(SELECT 1 FROM information_schema.tables WHERE table_schema='\(t)' AND table_name='dst')")
            XCTAssertTrue(exists)
            let count = try await db.scalarInt("SELECT count(*)::int FROM \"\(t)\".dst")
            XCTAssertEqual(count, 2)
        } catch { await db.dropSchemas(s, t); throw error }
        await db.dropSchemas(s, t)
    }

    func testUpsertUpdatesConflictsAndInsertsNew() async throws {
        let db = try await TestDB.connectOrSkip(); defer { db.shutdown() }
        let s = TestDB.uniqueTag(); let t = TestDB.uniqueTag()
        await db.dropSchemas(s, t)
        do {
            try await db.exec("""
            CREATE SCHEMA "\(s)"; CREATE SCHEMA "\(t)";
            CREATE TABLE "\(s)".src (id int PRIMARY KEY, v text);
            INSERT INTO "\(s)".src VALUES (1,'a'),(2,'b'),(3,'c');
            CREATE TABLE "\(t)".dst (id int PRIMARY KEY, v text);
            INSERT INTO "\(t)".dst VALUES (1,'OLD');
            """)
            let srcNode = TableNode(schema: s, name: "src", kind: .table,
                                    columns: [col("id"), col("v", "text")], primaryKey: ["id"])
            let plan = CrossDBCopy.Plan(
                source: srcNode, sourceClient: db.client, target: .existing(db.client),
                targetSchema: t, targetTable: "dst", strategy: .upsert,
                mappings: [map("id", "integer", to: "id"), map("v", "text", to: "v")],
                conflictColumns: ["id"])
            let stats = try await CrossDBCopy.execute(plan: plan)
            XCTAssertEqual(stats.rowsCopied, 3)
            let count = try await db.scalarInt("SELECT count(*)::int FROM \"\(t)\".dst")
            XCTAssertEqual(count, 3)
            let v1 = try await db.scalarString("SELECT v FROM \"\(t)\".dst WHERE id=1")
            XCTAssertEqual(v1, "a", "conflict row updated from EXCLUDED")
            let v3 = try await db.scalarString("SELECT v FROM \"\(t)\".dst WHERE id=3")
            XCTAssertEqual(v3, "c", "new row inserted")
        } catch { await db.dropSchemas(s, t); throw error }
        await db.dropSchemas(s, t)
    }
}
