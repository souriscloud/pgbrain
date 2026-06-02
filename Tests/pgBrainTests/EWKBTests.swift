import XCTest
import NIOCore
@testable import pgBrain

/// Pure coverage of the EWKB → EWKT reader. Geometries are hand-built byte by
/// byte so the test has no PostGIS dependency.
final class EWKBTests: XCTestCase {

    // little-endian encoders
    private func u32(_ v: UInt32) -> [UInt8] { (0..<4).map { UInt8((v >> (8 * UInt32($0))) & 0xff) } }
    private func f64(_ v: Double) -> [UInt8] {
        let b = v.bitPattern; return (0..<8).map { UInt8((b >> (8 * UInt64($0))) & 0xff) }
    }
    /// A standalone point record (order byte + type + optional srid + coords).
    private func point(_ x: Double, _ y: Double, srid: UInt32? = nil, z: Double? = nil) -> [UInt8] {
        var type: UInt32 = 1
        if srid != nil { type |= 0x2000_0000 }
        if z != nil { type |= 0x8000_0000 }
        var b: [UInt8] = [1] + u32(type)
        if let s = srid { b += u32(s) }
        b += f64(x) + f64(y)
        if let z { b += f64(z) }
        return b
    }
    private func buf(_ bytes: [UInt8]) -> ByteBuffer { ByteBuffer(bytes: bytes) }

    func testPointWithSRID() {
        XCTAssertEqual(EWKB.toEWKT(buf(point(1, 2, srid: 4326))), "SRID=4326;POINT(1 2)")
    }

    func testPointWithoutSRID() {
        XCTAssertEqual(EWKB.toEWKT(buf(point(3, 4))), "POINT(3 4)")
    }

    func testPointZ() {
        XCTAssertEqual(EWKB.toEWKT(buf(point(1, 2, z: 3))), "POINT(1 2 3)")
    }

    func testFractionalCoordFormatting() {
        // Non-integer value goes through the %.12g branch.
        XCTAssertEqual(EWKB.toEWKT(buf(point(1.5, 2))), "POINT(1.5 2)")
    }

    func testLineString() {
        let bytes: [UInt8] = [1] + u32(2) + u32(2) + f64(1) + f64(2) + f64(3) + f64(4)
        XCTAssertEqual(EWKB.toEWKT(buf(bytes)), "LINESTRING(1 2, 3 4)")
    }

    func testPolygon() {
        // one ring, four points (closed)
        let ring = u32(4) + f64(0) + f64(0) + f64(1) + f64(0) + f64(1) + f64(1) + f64(0) + f64(0)
        let bytes: [UInt8] = [1] + u32(3) + u32(1) + ring
        XCTAssertEqual(EWKB.toEWKT(buf(bytes)), "POLYGON((0 0, 1 0, 1 1, 0 0))")
    }

    func testMultiPoint() {
        let bytes: [UInt8] = [1] + u32(4) + u32(2) + point(1, 2) + point(3, 4)
        XCTAssertEqual(EWKB.toEWKT(buf(bytes)), "MULTIPOINT(1 2, 3 4)")
    }

    func testMultiLineString() {
        let line: ([UInt8]) = [1] + u32(2) + u32(2) + f64(0) + f64(0) + f64(1) + f64(1)
        let bytes: [UInt8] = [1] + u32(5) + u32(1) + line
        XCTAssertEqual(EWKB.toEWKT(buf(bytes)), "MULTILINESTRING((0 0, 1 1))")
    }

    func testMultiPolygon() {
        let ring = u32(4) + f64(0) + f64(0) + f64(1) + f64(0) + f64(1) + f64(1) + f64(0) + f64(0)
        let poly: [UInt8] = [1] + u32(3) + u32(1) + ring
        let bytes: [UInt8] = [1] + u32(6) + u32(1) + poly
        XCTAssertEqual(EWKB.toEWKT(buf(bytes)), "MULTIPOLYGON(((0 0, 1 0, 1 1, 0 0)))")
    }

    func testGeometryCollection() {
        let bytes: [UInt8] = [1] + u32(7) + u32(2) + point(1, 2) + point(3, 4)
        XCTAssertEqual(EWKB.toEWKT(buf(bytes)), "GEOMETRYCOLLECTION(POINT(1 2), POINT(3 4))")
    }

    func testBigEndianPoint() {
        // order byte 0, big-endian type + coords
        func u32be(_ v: UInt32) -> [UInt8] { (0..<4).map { UInt8((v >> (8 * (3 - UInt32($0)))) & 0xff) } }
        func f64be(_ v: Double) -> [UInt8] { let b = v.bitPattern; return (0..<8).map { UInt8((b >> (8 * (7 - UInt64($0)))) & 0xff) } }
        let bytes: [UInt8] = [0] + u32be(1) + f64be(1) + f64be(2)
        XCTAssertEqual(EWKB.toEWKT(buf(bytes)), "POINT(1 2)")
    }

    // MARK: rejection paths

    func testNilBuffer() {
        XCTAssertNil(EWKB.toEWKT(nil))
    }

    func testLeftoverBytesRejected() {
        XCTAssertNil(EWKB.toEWKT(buf(point(1, 2) + [0xFF])), "trailing bytes ⇒ not a clean geometry")
    }

    func testUnknownTypeRejected() {
        XCTAssertNil(EWKB.toEWKT(buf([1] + u32(99) + f64(1) + f64(2))))
    }

    func testTruncatedRejected() {
        XCTAssertNil(EWKB.toEWKT(buf([1] + u32(1) + f64(1))), "missing the second coordinate")
        XCTAssertNil(EWKB.toEWKT(buf([1])), "header only")
        XCTAssertNil(EWKB.toEWKT(buf([])), "empty")
    }
}
