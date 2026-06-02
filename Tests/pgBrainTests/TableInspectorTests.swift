import XCTest
import PostgresNIO
@testable import pgBrain

@MainActor
final class TableInspectorTests: XCTestCase {

    func testFetchRichTableAndRenderDDL() async throws {
        let db = try await TestDB.connectOrSkip(); defer { db.shutdown() }
        let s = TestDB.uniqueTag(); await db.dropSchemas(s)
        do {
            try await db.exec("""
            CREATE SCHEMA "\(s)";
            CREATE TABLE "\(s)".parent (id int PRIMARY KEY);
            CREATE TABLE "\(s)".t (
              id int GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
              email text NOT NULL UNIQUE,
              parent_id int REFERENCES "\(s)".parent(id),
              amount numeric DEFAULT 0,
              full_name text GENERATED ALWAYS AS (email) STORED,
              CONSTRAINT amount_pos CHECK (amount >= 0)
            );
            CREATE INDEX t_amount_idx ON "\(s)".t (amount);
            COMMENT ON TABLE "\(s)".t IS 'rich table';
            COMMENT ON COLUMN "\(s)".t.email IS 'the email';
            """)
            // Trigger function body has an internal ';' → single statements.
            _ = try await db.client.query(PostgresQuery(unsafeSQL:
                "CREATE FUNCTION \"\(s)\".noop() RETURNS trigger LANGUAGE plpgsql AS $$BEGIN RETURN NEW; END$$"))
            _ = try await db.client.query(PostgresQuery(unsafeSQL:
                "CREATE TRIGGER trg BEFORE INSERT ON \"\(s)\".t FOR EACH ROW EXECUTE FUNCTION \"\(s)\".noop()"))

            let snap = try await TableInspector.fetch(client: db.client, schema: s, table: "t")
            XCTAssertEqual(snap.kind, .table)
            XCTAssertEqual(snap.comment, "rich table")

            let byName = Dictionary(uniqueKeysWithValues: snap.columns.map { ($0.name, $0) })
            XCTAssertEqual(byName["id"]?.identity, "a", "GENERATED ALWAYS AS IDENTITY")
            XCTAssertEqual(byName["email"]?.nullable, false)
            XCTAssertEqual(byName["email"]?.comment, "the email")
            XCTAssertEqual(byName["amount"]?.defaultExpr, "0")
            XCTAssertEqual(byName["full_name"]?.generated, "s", "stored generated column")
            XCTAssertNotNil(byName["full_name"]?.defaultExpr, "generation expression present")

            // PK, UK, FK, CHECK all surfaced; ordered PK→UK→FK→CHECK.
            let kinds = snap.constraints.map { $0.kind }
            XCTAssertTrue(kinds.contains("p") && kinds.contains("u") && kinds.contains("f") && kinds.contains("c"))
            XCTAssertEqual(kinds.first, "p", "primary key ordered first")

            // The standalone index is listed; PK/UK-backing indexes are excluded.
            XCTAssertTrue(snap.indexes.contains { $0.name == "t_amount_idx" })
            XCTAssertFalse(snap.indexes.contains { $0.definition.contains("UNIQUE") && $0.name.contains("email") })

            let trg = try XCTUnwrap(snap.triggers.first { $0.name == "trg" })
            XCTAssertTrue(trg.enabled)
            XCTAssertTrue(trg.definition.contains("BEFORE INSERT"))

            XCTAssertNil(snap.partitioning)

            // Render the recreate-DDL and spot-check the interesting clauses.
            let ddl = try await TableInspector.renderDDL(client: db.client, snapshot: snap)
            XCTAssertTrue(ddl.contains("CREATE TABLE"))
            XCTAssertTrue(ddl.contains("GENERATED ALWAYS AS IDENTITY"))
            XCTAssertTrue(ddl.contains("GENERATED ALWAYS AS (email) STORED"))
            XCTAssertTrue(ddl.contains("NOT NULL"))
            XCTAssertTrue(ddl.contains("DEFAULT 0"))
            XCTAssertTrue(ddl.contains("CONSTRAINT"))
            XCTAssertTrue(ddl.contains("CREATE INDEX") || ddl.contains("t_amount_idx"))
            XCTAssertTrue(ddl.contains("COMMENT ON TABLE"))
            XCTAssertTrue(ddl.contains("COMMENT ON COLUMN"))
            XCTAssertTrue(ddl.contains("'rich table'"))
        } catch { await db.dropSchemas(s); throw error }
        await db.dropSchemas(s)
    }

    func testFetchViewAndMaterializedViewDDL() async throws {
        let db = try await TestDB.connectOrSkip(); defer { db.shutdown() }
        let s = TestDB.uniqueTag(); await db.dropSchemas(s)
        do {
            try await db.exec("""
            CREATE SCHEMA "\(s)";
            CREATE TABLE "\(s)".t (id int);
            CREATE VIEW "\(s)".v AS SELECT id FROM "\(s)".t;
            CREATE MATERIALIZED VIEW "\(s)".mv AS SELECT id FROM "\(s)".t;
            COMMENT ON VIEW "\(s)".v IS 'a view';
            """)
            let vsnap = try await TableInspector.fetch(client: db.client, schema: s, table: "v")
            XCTAssertEqual(vsnap.kind, .view)
            let vddl = try await TableInspector.renderDDL(client: db.client, snapshot: vsnap)
            XCTAssertTrue(vddl.contains("CREATE OR REPLACE VIEW"))
            XCTAssertTrue(vddl.contains("COMMENT ON VIEW"))
            XCTAssertTrue(vddl.contains("'a view'"))

            let mvsnap = try await TableInspector.fetch(client: db.client, schema: s, table: "mv")
            XCTAssertEqual(mvsnap.kind, .materializedView)
            let mvddl = try await TableInspector.renderDDL(client: db.client, snapshot: mvsnap)
            XCTAssertTrue(mvddl.contains("CREATE OR REPLACE MATERIALIZED VIEW"))
        } catch { await db.dropSchemas(s); throw error }
        await db.dropSchemas(s)
    }

    func testFetchPartitionedTable() async throws {
        let db = try await TestDB.connectOrSkip(); defer { db.shutdown() }
        let s = TestDB.uniqueTag(); await db.dropSchemas(s)
        do {
            try await db.exec("""
            CREATE SCHEMA "\(s)";
            CREATE TABLE "\(s)".events (id int, created date) PARTITION BY RANGE (created);
            CREATE TABLE "\(s)".events_2024 PARTITION OF "\(s)".events FOR VALUES FROM ('2024-01-01') TO ('2025-01-01');
            """)
            let snap = try await TableInspector.fetch(client: db.client, schema: s, table: "events")
            let part = try XCTUnwrap(snap.partitioning)
            XCTAssertEqual(part.strategy, "range")
            XCTAssertTrue(part.key.uppercased().contains("RANGE"))
            let child = try XCTUnwrap(part.children.first { $0.name == "events_2024" })
            XCTAssertEqual(child.schema, s)
            XCTAssertTrue(child.bound.contains("FROM"))
        } catch { await db.dropSchemas(s); throw error }
        await db.dropSchemas(s)
    }

    func testFetchNotFoundThrows() async throws {
        let db = try await TestDB.connectOrSkip(); defer { db.shutdown() }
        do {
            _ = try await TableInspector.fetch(client: db.client, schema: "public", table: "no_such_relation_xyz")
            XCTFail("expected notFound")
        } catch let TableInspector.InspectorError.notFound(schema, table) {
            XCTAssertEqual(schema, "public")
            XCTAssertEqual(table, "no_such_relation_xyz")
        }
        XCTAssertEqual(
            TableInspector.InspectorError.notFound(schema: "s", table: "t").errorDescription,
            "Relation s.t not found")
    }

    // Hand-built snapshots exercise the render branches a single live table
    // can't cover at once (by-default identity, plain default, no constraints).
    func testRenderDDLBranchesFromSnapshot() async throws {
        let db = try await TestDB.connectOrSkip(); defer { db.shutdown() }
        func column(_ name: String, _ type: String, nullable: Bool = true,
                    def: String? = nil, identity: String? = nil, generated: String? = nil,
                    comment: String? = nil, ord: Int = 1) -> TableInspector.Column {
            TableInspector.Column(name: name, typeName: type, nullable: nullable, defaultExpr: def,
                                  identity: identity, generated: generated, comment: comment, ordinal: ord)
        }
        let snap = TableInspector.Snapshot(
            schema: "s", table: "t", kind: .table, comment: nil,
            columns: [
                column("id", "integer", nullable: false, identity: "d"),         // BY DEFAULT
                column("note", "text", def: "'hi'::text", comment: "a note"),    // plain DEFAULT + col comment
            ],
            constraints: [],
            indexes: [TableInspector.Index(name: "t_note_idx", definition: "CREATE INDEX t_note_idx ON s.t (note)")],
            triggers: [],
            partitioning: nil
        )
        let ddl = try await TableInspector.renderDDL(client: db.client, snapshot: snap)
        XCTAssertTrue(ddl.contains("GENERATED BY DEFAULT AS IDENTITY"))
        XCTAssertTrue(ddl.contains("DEFAULT 'hi'::text"))
        XCTAssertTrue(ddl.contains("CREATE INDEX t_note_idx"))
        XCTAssertTrue(ddl.contains("COMMENT ON COLUMN"))
        XCTAssertFalse(ddl.contains("COMMENT ON TABLE"), "nil table comment → no table COMMENT line")
    }
}
