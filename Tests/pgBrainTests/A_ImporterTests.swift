import XCTest
import PostgresNIO
@testable import pgBrain

final class A_ImporterTests: XCTestCase {

    private func reader(_ bytes: [UInt8], encoding: String.Encoding = .utf8) -> CSVReader {
        let s = InputStream(data: Data(bytes))
        s.open()
        return CSVReader(stream: s, delimiter: UInt8(ascii: ","), encoding: encoding)
    }
    private func reader(_ text: String) -> CSVReader { reader(Array(text.utf8)) }

    private func records(_ r: CSVReader) throws -> [[String]] {
        var out: [[String]] = []
        while let rec = try r.readRecord() { out.append(rec.map(\.text)) }
        return out
    }

    private func col(_ name: String, _ type: String = "text", _ ord: Int = 0) -> ColumnNode {
        ColumnNode(name: name, typeName: type, nullable: true, ordinal: ord)
    }

    private func tempFile(_ bytes: [UInt8], ext: String = "csv") throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("pgb-import-\(UUID().uuidString).\(ext)")
        try Data(bytes).write(to: url)
        return url
    }

    // MARK: CSV reader

    func testBOMIsStripped() throws {
        let r = reader([0xEF, 0xBB, 0xBF] + Array("id,name\n1,a\n".utf8))
        XCTAssertEqual(try records(r), [["id", "name"], ["1", "a"]])
    }

    func testBlankLinesSkipped() throws {
        XCTAssertEqual(try records(reader("a,b\n\n1,2\r\n\r\n3,4\n\n")), [["a", "b"], ["1", "2"], ["3", "4"]])
    }

    func testQuotedEmptyDistinctFromEmpty() throws {
        let r = reader("x,\"\",y\n")
        let rec = try XCTUnwrap(try r.readRecord())
        XCTAssertEqual(rec.map(\.quoted), [false, true, false])
        let line = try Importer.encodeCSVRow([rec[1], CSVReader.Cell(text: "", quoted: false)],
                                             expectedCells: 2, emptyAsNull: true, line: 1)
        XCTAssertEqual(line, "\t\\N\n", "quoted \"\" stays empty string, bare empty becomes NULL")
    }

    func testEmbeddedNewlinesAndLineNumbers() throws {
        let r = reader("h\n\"a\nb\"\nc\n")
        _ = try r.readRecord()
        XCTAssertEqual(try r.readRecord()?.map(\.text), ["a\nb"])
        XCTAssertEqual(r.recordLine, 2)
        XCTAssertEqual(try r.readRecord()?.map(\.text), ["c"])
        XCTAssertEqual(r.recordLine, 4)
    }

    func testInvalidUTF8Throws() {
        let r = reader(Array("ok\n".utf8) + [0xC3, 0x28, 0x0A])
        XCTAssertNoThrow(try r.readRecord())
        XCTAssertThrowsError(try r.readRecord()) { err in
            XCTAssertEqual(err as? Importer.ImportError, .invalidEncoding(line: 2, encoding: "UTF-8"))
        }
    }

    func testWindows1250Decoding() throws {
        // "žluť" in cp1250: 9E 6C 75 9D
        let r = reader([0x9E, 0x6C, 0x75, 0x9D, 0x0A], encoding: .windowsCP1250)
        XCTAssertEqual(try r.readRecord()?.map(\.text), ["žluť"])
    }

    func testUnterminatedQuoteThrows() {
        XCTAssertThrowsError(try reader("\"abc\n").readRecord())
    }

    func testTooManyCellsIsAnError() {
        let cells = ["1", "2", "3"].map { CSVReader.Cell(text: $0, quoted: false) }
        XCTAssertThrowsError(try Importer.encodeCSVRow(cells, expectedCells: 2, emptyAsNull: true, line: 7)) { err in
            XCTAssertEqual(err as? Importer.ImportError, .tooManyCells(line: 7, expected: 2, got: 3))
        }
    }

    // MARK: header planning

    func testHeaderSubsetAndReorderPlansCopyColumnsInHeaderOrder() throws {
        let cols = [col("id", "integer", 0), col("name", "text", 1), col("note", "text", 2)]
        let r = reader("note,id\nhello,5\n")
        let plan = try Importer.planColumns(reader: r, columns: cols, options: .init())
        XCTAssertEqual(plan.copyColumns, ["note", "id"])
        let row = try XCTUnwrap(try r.readRecord())
        XCTAssertEqual(try Importer.encodeCSVRow(row, expectedCells: 2, emptyAsNull: true, line: 2), "hello\t5\n")
    }

    func testDuplicateHeaderRejected() {
        let r = reader("id,id\n")
        XCTAssertThrowsError(try Importer.planColumns(reader: r, columns: [col("id")], options: .init()))
    }

    // MARK: encodings / BOM sniffing

    func testUTF16FileIsTranscoded() throws {
        var bytes: [UInt8] = [0xFF, 0xFE]
        for unit in "a,č\n".utf16 { bytes += [UInt8(unit & 0xFF), UInt8(unit >> 8)] }
        let url = try tempFile(bytes); defer { try? FileManager.default.removeItem(at: url) }
        let (stream, enc) = try Importer.openCSVSource(url, encoding: .utf8)
        stream.open(); defer { stream.close() }
        let r = CSVReader(stream: stream, delimiter: UInt8(ascii: ","), encoding: enc)
        XCTAssertEqual(try r.readRecord()?.map(\.text), ["a", "č"])
    }

    func testCopyTextEscapeHandlesCRLFCharacter() {
        XCTAssertEqual(Importer.copyTextEscape("a\r\nb\\c\td"), "a\\r\\nb\\\\c\\td")
    }

    // MARK: JSON

    func testLosslessJSONKeepsNumbersAndBooleans() throws {
        let json = #"[{"id": 9007199254740993, "flag": true, "n": 0, "m": 1, "amt": 12.3400, "e": 1e400}]"#
        let cols = ["id", "flag", "n", "m", "amt", "e"].enumerated().map { col($1, "text", $0) }
        let (names, lines) = try Importer.jsonCopyPlan(data: Data(json.utf8), encoding: .utf8, columns: cols)
        XCTAssertEqual(names, ["id", "flag", "n", "m", "amt", "e"])
        XCTAssertEqual(lines, ["9007199254740993\ttrue\t0\t1\t12.3400\t1e400\n"])
    }

    func testJSONOnlyCopiesPresentKeysAndNestedAsJSON() throws {
        let json = #"[{"b": {"x": [1, 2.50, "s\"q"]}}, {"b": null}]"#
        let cols = [col("a", "integer", 0), col("b", "jsonb", 1)]
        let (names, lines) = try Importer.jsonCopyPlan(data: Data(json.utf8), encoding: .utf8, columns: cols)
        XCTAssertEqual(names, ["b"], "absent key `a` keeps its DEFAULT")
        XCTAssertEqual(lines, [#"{"x":[1,2.50,"s\\"q"]}"# + "\n", "\\N\n"])
    }

    func testJSONStringEscapesAndSurrogates() throws {
        let v = try LosslessJSON.parse(Array(#""a\u00e9\ud83d\ude00\n""#.utf8))
        XCTAssertEqual(v, .string("aé😀\n"))
    }

    func testJSONErrors() {
        XCTAssertThrowsError(try LosslessJSON.parse(Array("[1,]".utf8)))
        XCTAssertThrowsError(try LosslessJSON.parse(Array("01".utf8)))
        XCTAssertThrowsError(try Importer.jsonCopyPlan(data: Data(#"{"a":1}"#.utf8), encoding: .utf8, columns: [col("a")]))
        XCTAssertThrowsError(try Importer.jsonCopyPlan(data: Data(#"[{"zz":1}]"#.utf8), encoding: .utf8, columns: [col("a")]))
    }

    func testJSONWithBOM() throws {
        let (names, _) = try Importer.jsonCopyPlan(data: Data([0xEF, 0xBB, 0xBF] + Array(#"[{"a":1}]"#.utf8)),
                                                   encoding: .utf8, columns: [col("a")])
        XCTAssertEqual(names, ["a"])
    }

    // MARK: E2E

    func testCSVImportWithReorderedSubsetHeader() async throws {
        let db = try await TestDB.connectOrSkip(); defer { db.shutdown() }
        let s = TestDB.uniqueTag()
        await db.dropSchemas(s)
        do {
            try await db.exec("""
            CREATE SCHEMA "\(s)";
            CREATE TABLE "\(s)".t (id int PRIMARY KEY, name text, note text DEFAULT 'dflt', qty int)
            """)
            let table = TableNode(schema: s, name: "t", kind: .table,
                                  columns: [col("id", "integer", 0), col("name", "text", 1),
                                            col("note", "text", 2), col("qty", "integer", 3)])
            let csv = [0xEF, 0xBB, 0xBF] + Array("qty,name,id\r\n5,\"a,b\",1\r\n\r\n,\"\",2\r\n".utf8)
            let url = try tempFile(csv); defer { try? FileManager.default.removeItem(at: url) }
            let stats = try await Importer.importCSV(into: table, from: url, client: db.client)
            XCTAssertEqual(stats.rowsImported, 2)
            let v1 = try await db.scalarString("SELECT name || '|' || note || '|' || qty FROM \"\(s)\".t WHERE id = 1")
            XCTAssertEqual(v1, "a,b|dflt|5")
            let v2 = try await db.scalarBool("SELECT name = '' AND qty IS NULL FROM \"\(s)\".t WHERE id = 2")
            XCTAssertEqual(v2, true)
        } catch { await db.dropSchemas(s); throw error }
        await db.dropSchemas(s)
    }

    func testCSVImportRollsBackOnTooManyCells() async throws {
        let db = try await TestDB.connectOrSkip(); defer { db.shutdown() }
        let s = TestDB.uniqueTag()
        await db.dropSchemas(s)
        do {
            try await db.exec("CREATE SCHEMA \"\(s)\"; CREATE TABLE \"\(s)\".t (id int, name text)")
            let table = TableNode(schema: s, name: "t", kind: .table, columns: [col("id", "integer", 0), col("name", "text", 1)])
            let url = try tempFile(Array("id,name\n1,a\n2,b,EXTRA\n".utf8)); defer { try? FileManager.default.removeItem(at: url) }
            do {
                _ = try await Importer.importCSV(into: table, from: url, client: db.client)
                XCTFail("expected tooManyCells")
            } catch let e as Importer.ImportError {
                XCTAssertEqual(e, .tooManyCells(line: 3, expected: 2, got: 3))
            }
            let v3 = try await db.scalarInt("SELECT count(*)::int FROM \"\(s)\".t")
            XCTAssertEqual(v3, 0)
        } catch { await db.dropSchemas(s); throw error }
        await db.dropSchemas(s)
    }

    func testJSONImportKeepsBigintPrecision() async throws {
        let db = try await TestDB.connectOrSkip(); defer { db.shutdown() }
        let s = TestDB.uniqueTag()
        await db.dropSchemas(s)
        do {
            try await db.exec("""
            CREATE SCHEMA "\(s)";
            CREATE TABLE "\(s)".t (id bigserial PRIMARY KEY, big bigint, amt numeric(20,4), n int, doc jsonb)
            """)
            let table = TableNode(schema: s, name: "t", kind: .table,
                                  columns: [col("id", "bigint", 0), col("big", "bigint", 1), col("amt", "numeric", 2),
                                            col("n", "integer", 3), col("doc", "jsonb", 4)])
            let json = #"[{"big": 9007199254740993, "amt": 1234567890123456.1234, "n": 1, "doc": {"k": [true, 0]}}]"#
            let url = try tempFile(Array(json.utf8), ext: "json"); defer { try? FileManager.default.removeItem(at: url) }
            let stats = try await Importer.importJSON(into: table, from: url, client: db.client)
            XCTAssertEqual(stats.rowsImported, 1)
            let v4 = try await db.scalarString("SELECT big::text FROM \"\(s)\".t")
            XCTAssertEqual(v4, "9007199254740993")
            let v5 = try await db.scalarString("SELECT amt::text FROM \"\(s)\".t")
            XCTAssertEqual(v5, "1234567890123456.1234")
            let v6 = try await db.scalarInt("SELECT n FROM \"\(s)\".t")
            XCTAssertEqual(v6, 1)
            let v7 = try await db.scalarString("SELECT doc::text FROM \"\(s)\".t")
            XCTAssertEqual(v7, #"{"k": [true, 0]}"#)
            let v8 = try await db.scalarInt("SELECT id::int FROM \"\(s)\".t")
            XCTAssertEqual(v8, 1, "absent id → DEFAULT")
        } catch { await db.dropSchemas(s); throw error }
        await db.dropSchemas(s)
    }
}
