import XCTest
import PostgresNIO
@testable import pgBrain

final class C_PGTemporalTests: XCTestCase {

    private func roundTrip(_ s: String, _ k: PGTemporal.Kind, file: StaticString = #filePath, line: UInt = #line) {
        guard let v = PGTemporal.parse(s, kind: k) else {
            return XCTFail("failed to parse \(s)", file: file, line: line)
        }
        XCTAssertEqual(v.format(kind: k), s, file: file, line: line)
    }

    func testKindFromTypeName() {
        XCTAssertEqual(PGTemporal.Kind.from(typeName: "date"), .date)
        XCTAssertEqual(PGTemporal.Kind.from(typeName: "time without time zone"), .time(tz: false))
        XCTAssertEqual(PGTemporal.Kind.from(typeName: "time(3) with time zone"), .time(tz: true))
        XCTAssertEqual(PGTemporal.Kind.from(typeName: "timestamp(6) without time zone"), .timestamp(tz: false))
        XCTAssertEqual(PGTemporal.Kind.from(typeName: "timestamp with time zone"), .timestamp(tz: true))
        XCTAssertEqual(PGTemporal.Kind.from(typeName: "timestamptz"), .timestamp(tz: true))
        XCTAssertNil(PGTemporal.Kind.from(typeName: "text"))
    }

    func testPostgresOutputRoundTripsExactly() {
        roundTrip("2024-03-05", .date)
        roundTrip("0044-03-15 BC", .date)
        roundTrip("infinity", .date)
        roundTrip("-infinity", .timestamp(tz: true))
        roundTrip("13:45:00", .time(tz: false))
        roundTrip("13:45:07.5", .time(tz: false))
        roundTrip("13:45:07.123456", .time(tz: false))
        roundTrip("24:00:00", .time(tz: false))
        roundTrip("13:45:07.01+05:30", .time(tz: true))
        roundTrip("2024-03-05 13:45:07", .timestamp(tz: false))
        roundTrip("2024-03-05 13:45:07.1", .timestamp(tz: false))
        roundTrip("2024-03-05 13:45:07.000001", .timestamp(tz: false))
        roundTrip("2024-03-05 13:45:07.123456+01", .timestamp(tz: true))
        roundTrip("2024-03-05 13:45:07-08", .timestamp(tz: true))
        roundTrip("2024-03-05 13:45:07+05:45", .timestamp(tz: true))
        roundTrip("1883-11-18 11:59:59+00:53:28", .timestamp(tz: true))
        roundTrip("0044-03-15 12:00:00+00 BC", .timestamp(tz: true))
        roundTrip("12024-01-01 00:00:00", .timestamp(tz: false))
    }

    func testFractionalDigitsNormalise() {
        let v = PGTemporal.parse("2024-01-01 00:00:00.120", kind: .timestamp(tz: false))
        XCTAssertEqual(v?.microsecond, 120_000)
        XCTAssertEqual(v?.format(kind: .timestamp(tz: false)), "2024-01-01 00:00:00.12")
        let nine = PGTemporal.parse("10:00:00.123456789", kind: .time(tz: false))
        XCTAssertEqual(nine?.microsecond, 123_456)
    }

    func testUserTypedVariantsParse() {
        XCTAssertEqual(PGTemporal.parse("2024-01-02T03:04:05Z", kind: .timestamp(tz: true))?.offsetSeconds, 0)
        XCTAssertEqual(PGTemporal.parse("2024-01-02 03:04:05+0530", kind: .timestamp(tz: true))?.offsetSeconds, 19_800)
        XCTAssertEqual(PGTemporal.parse("2024-01-02 03:04", kind: .timestamp(tz: false))?.minute, 4)
        XCTAssertEqual(PGTemporal.parse("2024-01-02", kind: .timestamp(tz: false))?.hour, 0)
        XCTAssertEqual(PGTemporal.parse("+infinity", kind: .date)?.special, .infinity)
    }

    func testGarbageIsRejected() {
        XCTAssertNil(PGTemporal.parse("", kind: .date))
        XCTAssertNil(PGTemporal.parse("now", kind: .timestamp(tz: true)))
        XCTAssertNil(PGTemporal.parse("2024-13-01", kind: .date))
        XCTAssertNil(PGTemporal.parse("2024-01-01 25:00", kind: .timestamp(tz: false)))
        XCTAssertNil(PGTemporal.parse("2024-01-01x", kind: .date))
        XCTAssertNil(PGTemporal.parse("infinity", kind: .time(tz: false)))
        XCTAssertNil(PGTemporal.parse("12:00:00 junk", kind: .time(tz: true)))
    }

    func testOffsetFormatting() {
        XCTAssertEqual(PGTemporal.formatOffset(3600), "+01")
        XCTAssertEqual(PGTemporal.formatOffset(-28800), "-08")
        XCTAssertEqual(PGTemporal.formatOffset(19_800), "+05:30")
        XCTAssertEqual(PGTemporal.formatOffset(3208), "+00:53:28")
        XCTAssertEqual(PGTemporal.formatOffset(0), "+00")
    }

    /// The picker shows the value in its own offset, and changing the minute
    /// keeps seconds, microseconds and the offset.
    func testPickerMergeKeepsHiddenComponents() throws {
        let k = PGTemporal.Kind.timestamp(tz: true)
        let v = try XCTUnwrap(PGTemporal.parse("2024-03-05 13:45:07.123456+05:30", kind: k))
        let d = try XCTUnwrap(v.pickerDate(kind: k))
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = v.pickerTimeZone
        XCTAssertEqual(cal.component(.hour, from: d), 13)
        let moved = try XCTUnwrap(cal.date(byAdding: .minute, value: 10, to: d))
        XCTAssertEqual(v.merging(pickerDate: moved, kind: k).format(kind: k),
                       "2024-03-05 13:55:07.123456+05:30")
    }

    func testPickerMergeDateOnlyAndTimeOnly() throws {
        let dv = try XCTUnwrap(PGTemporal.parse("2024-03-05", kind: .date))
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = dv.pickerTimeZone
        let next = try XCTUnwrap(cal.date(byAdding: .day, value: 1, to: try XCTUnwrap(dv.pickerDate(kind: .date))))
        XCTAssertEqual(dv.merging(pickerDate: next, kind: .date).format(kind: .date), "2024-03-06")

        let tv = try XCTUnwrap(PGTemporal.parse("08:00:30.5", kind: .time(tz: false)))
        let later = try XCTUnwrap(cal.date(byAdding: .hour, value: 2, to: try XCTUnwrap(tv.pickerDate(kind: .time(tz: false)))))
        XCTAssertEqual(tv.merging(pickerDate: later, kind: .time(tz: false)).format(kind: .time(tz: false)), "10:00:30.5")
    }

    func testPickerUnavailableForSpecialAndBC() {
        XCTAssertNil(PGTemporal.parse("infinity", kind: .date)?.pickerDate(kind: .date))
        XCTAssertNil(PGTemporal.parse("0044-03-15 BC", kind: .date)?.pickerDate(kind: .date))
    }

    /// What the server actually prints, in odd zones, parses and formats back
    /// to the identical text — and a picker edit's output casts cleanly.
    func testServerOutputRoundTripsAgainstLivePostgres() async throws {
        let db = try await TestDB.connectOrSkip(); defer { db.shutdown() }
        let probes: [(String, String, PGTemporal.Kind)] = [
            ("'2024-03-05 13:45:07.123456+00'::timestamptz", "Asia/Kolkata", .timestamp(tz: true)),
            ("'2024-03-05 13:45:07.5+00'::timestamptz", "Europe/Prague", .timestamp(tz: true)),
            ("'1883-11-18 11:59:59+00'::timestamptz", "Europe/Amsterdam", .timestamp(tz: true)),
            ("'0044-03-15 12:00:00+00 BC'::timestamptz", "UTC", .timestamp(tz: true)),
            ("'infinity'::timestamptz", "UTC", .timestamp(tz: true)),
            ("'2024-03-05 13:45:07.000010'::timestamp", "UTC", .timestamp(tz: false)),
            ("'13:45:07.25'::time", "UTC", .time(tz: false)),
            ("'13:45:07.25+05:30'::timetz", "UTC", .time(tz: true)),
            ("'0044-03-15 BC'::date", "UTC", .date),
        ]
        for (expr, zone, kind) in probes {
            let text: String = try await db.client.withConnection { conn in
                _ = try await conn.query(PostgresQuery(unsafeSQL: "SET TIME ZONE '\(zone)'"), logger: pgbrainQuietLogger)
                let rows = try await conn.query(PostgresQuery(unsafeSQL: "SELECT (\(expr))::text"), logger: pgbrainQuietLogger)
                for try await v in rows.decode(String.self) { return v }
                return ""
            }
            let parsed = PGTemporal.parse(text, kind: kind)
            XCTAssertNotNil(parsed, "server text \(text) should parse")
            XCTAssertEqual(parsed?.format(kind: kind), text, "\(expr) in \(zone)")
        }
        let edited = try XCTUnwrap(PGTemporal.parse("2024-03-05 13:45:07.123456+05:30", kind: .timestamp(tz: true)))
        let same = try await db.scalarBool(
            "SELECT '\(edited.format(kind: .timestamp(tz: true)))'::timestamptz = '2024-03-05 08:15:07.123456+00'::timestamptz")
        XCTAssertTrue(same)
    }

    func testNowCarriesLocalOffsetForZonedKinds() throws {
        let zone = try XCTUnwrap(TimeZone(secondsFromGMT: 7200))
        let at = Date(timeIntervalSince1970: 1_700_000_000)   // 2023-11-14 22:13:20 UTC
        let tz = PGTemporal.now(kind: .timestamp(tz: true), at: at, zone: zone)
        XCTAssertEqual(tz.format(kind: .timestamp(tz: true)), "2023-11-15 00:13:20+02")
        let plain = PGTemporal.now(kind: .timestamp(tz: false), at: at, zone: zone)
        XCTAssertEqual(plain.format(kind: .timestamp(tz: false)), "2023-11-15 00:13:20")
    }
}
