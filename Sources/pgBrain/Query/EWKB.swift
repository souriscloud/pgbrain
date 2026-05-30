import NIOCore

/// Minimal EWKB (PostGIS extended well-known-binary) → EWKT reader. The
/// scratchpad runs raw SQL, so a geometry column arrives as binary EWKB rather
/// than text; this turns it into `SRID=4326;POINT(14.4378 50.0755)` so the grid
/// matches `ST_AsEWKT`. Returns nil for anything that isn't a clean geometry
/// (e.g. `bytea`), so the caller can fall back to hex.
enum EWKB {
    static func toEWKT(_ buffer: ByteBuffer?) -> String? {
        guard let buffer else { return nil }
        var reader = Reader(bytes: Array(buffer.readableBytesView))
        guard let result = reader.readGeometry(srid: nil),
              reader.consumedAll          // leftover bytes ⇒ not a clean geometry
        else { return nil }
        let prefix = result.srid.map { "SRID=\($0);" } ?? ""
        return prefix + result.wkt
    }

    private struct Reader {
        let bytes: [UInt8]
        var pos = 0
        var little = true

        var consumedAll: Bool { pos == bytes.count }

        mutating func u8() -> UInt8? {
            guard pos < bytes.count else { return nil }
            defer { pos += 1 }
            return bytes[pos]
        }

        mutating func u32() -> UInt32? {
            guard pos + 4 <= bytes.count else { return nil }
            let a = bytes[pos..<pos + 4]
            pos += 4
            let b = Array(a)
            return little
                ? UInt32(b[0]) | UInt32(b[1]) << 8 | UInt32(b[2]) << 16 | UInt32(b[3]) << 24
                : UInt32(b[3]) | UInt32(b[2]) << 8 | UInt32(b[1]) << 16 | UInt32(b[0]) << 24
        }

        mutating func f64() -> Double? {
            guard pos + 8 <= bytes.count else { return nil }
            var a = Array(bytes[pos..<pos + 8])
            pos += 8
            if !little { a.reverse() }
            var bits: UInt64 = 0
            for i in 0..<8 { bits |= UInt64(a[i]) << (8 * UInt64(i)) }
            return Double(bitPattern: bits)
        }

        mutating func readGeometry(srid inherited: UInt32?) -> (wkt: String, srid: UInt32?)? {
            guard let order = u8() else { return nil }
            little = (order == 1)
            guard let tw = u32() else { return nil }
            let hasZ = tw & 0x8000_0000 != 0
            let hasM = tw & 0x4000_0000 != 0
            let hasSRID = tw & 0x2000_0000 != 0
            let type = Int(tw & 0xFF)
            var srid = inherited
            if hasSRID { srid = u32() }
            let dims = 2 + (hasZ ? 1 : 0) + (hasM ? 1 : 0)

            switch type {
            case 1:
                guard let p = point(dims) else { return nil }
                return ("POINT(\(p))", srid)
            case 2:
                guard let pts = ring(dims) else { return nil }
                return ("LINESTRING(\(pts))", srid)
            case 3:
                guard let nr = u32() else { return nil }
                var rings: [String] = []
                for _ in 0..<nr { guard let r = ring(dims) else { return nil }; rings.append("(\(r))") }
                return ("POLYGON(\(rings.joined(separator: ", ")))", srid)
            case 4:
                return multi("MULTIPOINT", srid: srid) { Self.inner($0) }
            case 5:
                return multi("MULTILINESTRING", srid: srid) { "(\(Self.inner($0)))" }
            case 6:
                return multi("MULTIPOLYGON", srid: srid) { "(\(Self.inner($0)))" }
            case 7:
                guard let n = u32() else { return nil }
                var parts: [String] = []
                for _ in 0..<n { guard let g = readGeometry(srid: srid) else { return nil }; parts.append(g.wkt) }
                return ("GEOMETRYCOLLECTION(\(parts.joined(separator: ", ")))", srid)
            default:
                return nil
            }
        }

        /// Read N sub-geometries (each a full EWKB record) and wrap them.
        mutating func multi(_ keyword: String, srid: UInt32?, _ shape: (String) -> String) -> (wkt: String, srid: UInt32?)? {
            guard let n = u32() else { return nil }
            var parts: [String] = []
            for _ in 0..<n {
                guard let g = readGeometry(srid: srid) else { return nil }
                parts.append(shape(g.wkt))
            }
            return ("\(keyword)(\(parts.joined(separator: ", ")))", srid)
        }

        mutating func point(_ dims: Int) -> String? {
            var vals: [Double] = []
            for _ in 0..<dims { guard let d = f64() else { return nil }; vals.append(d) }
            return vals.map(Self.fmt).joined(separator: " ")
        }

        mutating func ring(_ dims: Int) -> String? {
            guard let n = u32() else { return nil }
            var pts: [String] = []
            for _ in 0..<n { guard let p = point(dims) else { return nil }; pts.append(p) }
            return pts.joined(separator: ", ")
        }

        /// Strip the `TYPE(` … `)` wrapper to inline a sub-geometry's coords.
        static func inner(_ wkt: String) -> String {
            guard let open = wkt.firstIndex(of: "("), wkt.hasSuffix(")") else { return wkt }
            return String(wkt[wkt.index(after: open)..<wkt.index(before: wkt.endIndex)])
        }

        static func fmt(_ d: Double) -> String {
            if d == d.rounded(), abs(d) < 1e15 { return String(Int64(d)) }
            return String(format: "%.12g", d)
        }
    }
}
