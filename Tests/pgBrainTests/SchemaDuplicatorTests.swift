import XCTest
import PostgresNIO
@testable import pgBrain

/// E2E: drive the real `SchemaDuplicator` engine against a live Postgres,
/// cloning a populated scratch schema and asserting the copy by re-querying.
/// This is the failure mode that actually matters — code that mutates a user's
/// database — frozen into assertions so it can't silently regress.
final class SchemaDuplicatorTests: XCTestCase {

    func testRoundTripClonesStructureDataViewsFKsAndIdentity() async throws {
        let db = try await TestDB.connectOrSkip()
        defer { db.shutdown() }

        let tag = TestDB.uniqueTag()
        let src = "\(tag)_src"
        let dst = "\(tag)_dst"
        await db.dropSchemas(src, dst)

        do {
            // ---- Source: identity PK, a serial child with an FK, data, a view.
            try await db.exec("""
            CREATE SCHEMA "\(src)";
            CREATE TABLE "\(src)".authors (
                id   int GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
                name text NOT NULL
            );
            CREATE TABLE "\(src)".books (
                id        serial PRIMARY KEY,
                author_id int NOT NULL REFERENCES "\(src)".authors(id),
                title     text
            );
            INSERT INTO "\(src)".authors (name) VALUES ('Ada'), ('Alan');
            INSERT INTO "\(src)".books (author_id, title)
                VALUES (1, 'Notes'), (1, 'Engine'), (2, 'Machinery');
            CREATE VIEW "\(src)".book_counts AS
                SELECT a.name, count(b.*) AS n
                FROM "\(src)".authors a
                LEFT JOIN "\(src)".books b ON b.author_id = a.id
                GROUP BY a.name;
            """)

            // ---- Clone everything.
            try await SchemaDuplicator.duplicate(client: db.client, from: src, to: dst,
                                                 options: SchemaDuplicator.Options())

            // ---- Structure + data copied.
            let authors = try await db.scalarInt("SELECT count(*) FROM \"\(dst)\".authors")
            XCTAssertEqual(authors, 2, "authors rows should round-trip")
            let books = try await db.scalarInt("SELECT count(*) FROM \"\(dst)\".books")
            XCTAssertEqual(books, 3, "books rows should round-trip")

            // ---- Foreign key preserved on the clone.
            let fks = try await db.scalarInt("""
            SELECT count(*) FROM pg_constraint con
            JOIN pg_class t ON t.oid = con.conrelid
            JOIN pg_namespace n ON n.oid = t.relnamespace
            WHERE n.nspname = '\(dst)' AND con.contype = 'f'
            """)
            XCTAssertEqual(fks, 1, "the books→authors FK should be recreated")

            // ---- View exists and resolves against the cloned tables (search_path
            //      retargeting), returning one row per author.
            let viewRows = try await db.scalarInt("SELECT count(*) FROM \"\(dst)\".book_counts")
            XCTAssertEqual(viewRows, 2, "the view should resolve to the cloned tables")

            // ---- Identity column kept as GENERATED ALWAYS (attidentity = 'a').
            let identityKept = try await db.scalarBool("""
            SELECT EXISTS (
                SELECT 1 FROM pg_attribute
                WHERE attrelid = '\(dst).authors'::regclass
                  AND attname = 'id' AND attidentity = 'a'
            )
            """)
            XCTAssertTrue(identityKept, "authors.id should stay GENERATED ALWAYS AS IDENTITY")

            // ---- Serial default repointed to the CLONED sequence, not the source.
            let serialRepointed = try await db.scalarBool("""
            SELECT pg_get_expr(ad.adbin, ad.adrelid) LIKE '%\(dst).%'
            FROM pg_attrdef ad
            JOIN pg_attribute a ON a.attrelid = ad.adrelid AND a.attnum = ad.adnum
            WHERE ad.adrelid = '\(dst).books'::regclass AND a.attname = 'id'
            """)
            XCTAssertTrue(serialRepointed, "books.id default should point at the cloned sequence")

            // ---- The clone's identity is usable: a fresh insert works end-to-end.
            try await db.exec("INSERT INTO \"\(dst)\".authors (name) VALUES ('Grace')")
            let afterInsert = try await db.scalarInt("SELECT count(*) FROM \"\(dst)\".authors")
            XCTAssertEqual(afterInsert, 3, "the cloned identity sequence should accept new rows")
        } catch {
            await db.dropSchemas(src, dst)
            throw error
        }
        await db.dropSchemas(src, dst)
    }

    /// Structure-only clone: tables present, but zero rows and no view.
    func testStructureOnlyClonesNoData() async throws {
        let db = try await TestDB.connectOrSkip()
        defer { db.shutdown() }

        let tag = TestDB.uniqueTag()
        let src = "\(tag)_src"
        let dst = "\(tag)_dst"
        await db.dropSchemas(src, dst)

        do {
            try await db.exec("""
            CREATE SCHEMA "\(src)";
            CREATE TABLE "\(src)".t (id int PRIMARY KEY, v text);
            INSERT INTO "\(src)".t VALUES (1, 'a'), (2, 'b');
            """)

            var opts = SchemaDuplicator.Options()
            opts.tableData = false
            opts.views = false
            opts.matviews = false
            opts.functions = false
            try await SchemaDuplicator.duplicate(client: db.client, from: src, to: dst, options: opts)

            let exists = try await db.scalarBool("SELECT to_regclass('\(dst).t') IS NOT NULL")
            XCTAssertTrue(exists, "table structure should be cloned")
            let rows = try await db.scalarInt("SELECT count(*) FROM \"\(dst)\".t")
            XCTAssertEqual(rows, 0, "data must NOT be copied when tableData is off")
        } catch {
            await db.dropSchemas(src, dst)
            throw error
        }
        await db.dropSchemas(src, dst)
    }
}
