import XCTest
import PostgresNIO
@testable import pgBrain

final class A_ExporterTests: XCTestCase {
    private func col(_ name: String, _ type: String, _ ord: Int) -> ColumnNode {
        ColumnNode(name: name, typeName: type, nullable: true, ordinal: ord)
    }

    private func tempDir() throws -> URL {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("pgb-export-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    private var page: RowsFetcher.Page {
        RowsFetcher.Page(
            columns: [col("id", "integer", 0), col("amt", "numeric", 1), col("f", "double precision", 2),
                      col("m", "money", 3), col("t", "text", 4)],
            rows: [
                ["1", "1.50", "NaN", "$1,234.00", ""],
                ["2", nil, "-Infinity", nil, nil],
                ["3", "1e400", "1.5e-3", "0", "a\r\nb"],
            ],
            truncated: false, limit: 100, offset: 0, elapsed: 0)
    }

    func testCSVDistinguishesNullFromEmpty() throws {
        let dir = try tempDir(); defer { try? FileManager.default.removeItem(at: dir) }
        let url = dir.appendingPathComponent("out.csv")
        _ = try Exporter.exportPage(page, format: .csv, destination: url)
        let text = try String(contentsOf: url, encoding: .utf8)
        XCTAssertTrue(text.contains("\n1,1.50,NaN,\"$1,234.00\",\"\"\n"), text)
        XCTAssertTrue(text.contains("\n2,,-Infinity,,\n"), text)
        XCTAssertTrue(text.contains(",\"a\r\nb\"\n"), "CRLF inside a value forces quoting")
    }

    func testJSONIsValidAndNonFiniteBecomesString() throws {
        let dir = try tempDir(); defer { try? FileManager.default.removeItem(at: dir) }
        let url = dir.appendingPathComponent("out.json")
        _ = try Exporter.exportPage(page, format: .json, destination: url)
        let data = try Data(contentsOf: url)
        // Strict RFC 8259 parse (JSONSerialization rejects the in-range-for-
        // numeric but not-for-Double 1e400, which is still valid JSON).
        guard case .array(let rows) = try LosslessJSON.parse([UInt8](data)) else { return XCTFail("not an array") }
        XCTAssertEqual(rows.count, 3)
        func field(_ r: Int, _ k: String) -> LosslessJSON.Value? {
            guard case .object(let pairs) = rows[r] else { return nil }
            return pairs.first { $0.key == k }?.value
        }
        XCTAssertEqual(field(0, "f"), .string("NaN"))
        XCTAssertEqual(field(0, "m"), .string("$1,234.00"))
        XCTAssertEqual(field(1, "f"), .string("-Infinity"))
        XCTAssertEqual(field(1, "amt"), .null)
        let text = String(decoding: data, as: UTF8.self)
        XCTAssertTrue(text.contains("\"amt\": 1.50"), "valid numbers stay unquoted with exact text")
        XCTAssertTrue(text.contains("\"amt\": 1e400"))
    }

    func testIsJSONNumber() {
        for ok in ["0", "-1", "1.5", "1e10", "1E+3", "-0.0e-1", "123456789012345678901234567890"] {
            XCTAssertTrue(Exporter.isJSONNumber(ok), ok)
        }
        for bad in ["NaN", "Infinity", "-Infinity", "01", "1.", ".5", "+1", "", "-", "$1", "1,000", "1e"] {
            XCTAssertFalse(Exporter.isJSONNumber(bad), bad)
        }
    }

    func testSuccessfulExportReplacesExistingFileAndLeavesNoTemp() throws {
        let dir = try tempDir(); defer { try? FileManager.default.removeItem(at: dir) }
        let url = dir.appendingPathComponent("out.csv")
        try Data("old".utf8).write(to: url)
        _ = try Exporter.exportPage(page, format: .csv, destination: url)
        XCTAssertTrue(try String(contentsOf: url, encoding: .utf8).hasPrefix("id,amt"))
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: dir.path), ["out.csv"])
    }

    func testFailedTableExportKeepsOldFileAndCleansTemp() async throws {
        let db = try await TestDB.connectOrSkip(); defer { db.shutdown() }
        let dir = try tempDir(); defer { try? FileManager.default.removeItem(at: dir) }
        let url = dir.appendingPathComponent("out.csv")
        try Data("previous".utf8).write(to: url)
        let missing = TableNode(schema: "public", name: "pgb_absent_\(UUID().uuidString.prefix(6))", kind: .table,
                                columns: [col("id", "integer", 0)])
        do {
            _ = try await Exporter.exportTable(missing, format: .csv, destination: url, client: db.client)
            XCTFail("export of a missing table must throw")
        } catch {}
        XCTAssertEqual(try String(contentsOf: url, encoding: .utf8), "previous")
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: dir.path), ["out.csv"])
    }

    func testTableExportRoundTripsNullAndEmpty() async throws {
        let db = try await TestDB.connectOrSkip(); defer { db.shutdown() }
        let s = TestDB.uniqueTag()
        await db.dropSchemas(s)
        let dir = try tempDir(); defer { try? FileManager.default.removeItem(at: dir) }
        do {
            try await db.exec("""
            CREATE SCHEMA "\(s)";
            CREATE TABLE "\(s)".t (id int, v text, d float8);
            INSERT INTO "\(s)".t VALUES (1, NULL, 'NaN'), (2, '', 'Infinity')
            """)
            let table = TableNode(schema: s, name: "t", kind: .table,
                                  columns: [col("id", "integer", 0), col("v", "text", 1), col("d", "double precision", 2)])
            let csvURL = dir.appendingPathComponent("t.csv")
            _ = try await Exporter.exportTable(table, format: .csv, destination: csvURL, client: db.client)
            let csv = try String(contentsOf: csvURL, encoding: .utf8)
            XCTAssertTrue(csv.contains("\n1,,NaN\n"), csv)
            XCTAssertTrue(csv.contains("\n2,\"\",Infinity\n"), csv)
            let jsonURL = dir.appendingPathComponent("t.json")
            _ = try await Exporter.exportTable(table, format: .json, destination: jsonURL, client: db.client)
            XCTAssertNoThrow(try JSONSerialization.jsonObject(with: Data(contentsOf: jsonURL)))
        } catch { await db.dropSchemas(s); throw error }
        await db.dropSchemas(s)
    }
}
