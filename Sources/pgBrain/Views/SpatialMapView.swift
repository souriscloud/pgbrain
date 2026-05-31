import SwiftUI
import MapKit
import PostgresNIO

/// Plots a table's geometry column on a real map. Fetches each feature as
/// GeoJSON (`ST_AsGeoJSON`), parses it client-side, and renders points as
/// markers, linestrings as polylines, and polygons as filled shapes —
/// auto-fitting the camera to the data's bounding box.
///
/// Coordinates are assumed to be lon/lat (SRID 4326) — the standard for
/// mappable data. Projected SRIDs would land off-map; a future pass can
/// `ST_Transform` them.
struct SpatialMapView: View {
    let service: ConnectionService
    /// SQL FROM target — a qualified table (`"app"."places"`) for a table tab,
    /// or a wrapped subquery (`(SELECT …) _pgb`) for a scratchpad result.
    let fromSQL: String
    let geometryColumn: String
    let labelColumn: String?
    /// search_path to apply before the fetch — needed when a scratchpad scopes
    /// itself to a specific schema and `fromSQL` uses unqualified table names.
    var searchPath: String? = nil

    @State private var features: [SpatialFeature] = []
    @State private var camera: MapCameraPosition = .automatic
    @State private var loading = true
    @State private var error: String?
    @State private var truncated = false

    private static let fetchLimit = 2000

    var body: some View {
        VStack(spacing: 0) {
            if loading {
                centered { ProgressView(); Text("Loading geometry…").font(.caption).foregroundStyle(.secondary) }
            } else if let error {
                centered {
                    Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange)
                    Text(error).font(.caption).foregroundStyle(.secondary).multilineTextAlignment(.center)
                }
            } else if features.isEmpty {
                centered {
                    Image(systemName: "mappin.slash").font(.system(size: 32)).foregroundStyle(.secondary)
                    Text("No geometry to plot in \(geometryColumn).").font(.callout).foregroundStyle(.secondary)
                }
            } else {
                Map(position: $camera) {
                    ForEach(features) { feature in
                        content(for: feature)
                    }
                }
                .mapStyle(.standard(elevation: .flat))
                footer
            }
        }
        .task(id: geometryColumn) { await load() }
    }

    @MapContentBuilder
    private func content(for feature: SpatialFeature) -> some MapContent {
        switch feature.geom {
        case .point(let c):
            Marker(feature.label, coordinate: c)
                .tint(Tokens.Brand.primary)
        case .line(let coords):
            MapPolyline(coordinates: coords)
                .stroke(Tokens.Brand.primary, lineWidth: 3)
        case .polygon(let coords):
            MapPolygon(coordinates: coords)
                .foregroundStyle(Tokens.Brand.primary.opacity(0.22))
                .stroke(Tokens.Brand.primary, lineWidth: 2)
        }
    }

    private var footer: some View {
        HStack(spacing: 6) {
            Image(systemName: "globe.europe.africa.fill").foregroundStyle(.green)
            Text("\(features.count) feature\(features.count == 1 ? "" : "s")\(truncated ? " (first \(Self.fetchLimit))" : "") · \(geometryColumn)")
                .font(.caption2).foregroundStyle(.secondary)
            Spacer()
            Text("WGS84 / lon-lat assumed").font(.caption2).foregroundStyle(.tertiary)
        }
        .padding(.horizontal, Tokens.Spacing.md)
        .padding(.vertical, 5)
        .background(Color(nsColor: .underPageBackgroundColor))
        .overlay(Divider(), alignment: .top)
    }

    @ViewBuilder
    private func centered<C: View>(@ViewBuilder _ content: () -> C) -> some View {
        VStack(spacing: Tokens.Spacing.sm) { content() }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func load() async {
        loading = true
        error = nil
        guard let client = service.client else { error = "Not connected."; loading = false; return }
        let geomQ = SQLIdent.quote(geometryColumn)
        let labelExpr = labelColumn.map { "\(SQLIdent.quote($0))::text" } ?? "NULL::text"
        let sql = """
        SELECT \(labelExpr) AS label, ST_AsGeoJSON(\(geomQ)) AS gj
        FROM \(fromSQL)
        WHERE \(geomQ) IS NOT NULL
        LIMIT \(Self.fetchLimit + 1)
        """
        do {
            // Decode to plain Sendable strings inside the connection scope (so
            // we can apply + reset search_path on that same connection), then
            // parse GeoJSON back on the main actor.
            let sp = searchPath
            let rows: [(String?, String?)] = try await client.withConnection { conn in
                if let sp { _ = try await conn.query(PostgresQuery(unsafeSQL: "SET search_path TO \(SQLIdent.quote(sp))"), logger: pgbrainQuietLogger) }
                do {
                    var collected: [(String?, String?)] = []
                    let stream = try await conn.query(PostgresQuery(unsafeSQL: sql), logger: pgbrainQuietLogger)
                    for try await row in stream.decode((String?, String?).self) {
                        collected.append(row)
                        if collected.count > Self.fetchLimit + 1 { break }
                    }
                    if sp != nil { _ = try? await conn.query(PostgresQuery(unsafeSQL: "RESET search_path"), logger: pgbrainQuietLogger) }
                    return collected
                } catch {
                    if sp != nil { _ = try? await conn.query(PostgresQuery(unsafeSQL: "RESET search_path"), logger: pgbrainQuietLogger) }
                    throw error
                }
            }
            var out: [SpatialFeature] = []
            var count = 0
            for (label, gj) in rows {
                count += 1
                if count > Self.fetchLimit { truncated = true; break }
                guard let gj else { continue }
                let geoms = GeoJSON.parse(gj)
                for g in geoms {
                    out.append(SpatialFeature(label: label ?? "#\(count)", geom: g))
                }
            }
            features = out
            if let region = Self.boundingRegion(out.flatMap { $0.geom.coordinates }) {
                camera = .region(region)
            }
            loading = false
        } catch {
            self.error = PostgresErrorMessage.describe(error)
            loading = false
        }
    }

    private static func boundingRegion(_ coords: [CLLocationCoordinate2D]) -> MKCoordinateRegion? {
        guard !coords.isEmpty else { return nil }
        let lats = coords.map(\.latitude), lons = coords.map(\.longitude)
        let minLat = lats.min()!, maxLat = lats.max()!
        let minLon = lons.min()!, maxLon = lons.max()!
        let center = CLLocationCoordinate2D(latitude: (minLat + maxLat) / 2, longitude: (minLon + maxLon) / 2)
        let span = MKCoordinateSpan(
            latitudeDelta: max(0.01, (maxLat - minLat) * 1.4),
            longitudeDelta: max(0.01, (maxLon - minLon) * 1.4)
        )
        return MKCoordinateRegion(center: center, span: span)
    }
}

/// Sniffs a result page for a geometry column so the scratchpad can offer a
/// map. Geometry cells render as WKT/EWKT (via the EWKB decoder), so we match
/// the WKT keyword prefixes.
enum SpatialDetect {
    static func looksLikeGeometry(_ s: String) -> Bool {
        let u = s.uppercased().trimmingCharacters(in: .whitespaces)
        if u.hasPrefix("SRID=") { return true }
        // A real WKT geometry has "(" after the type keyword. Requiring it
        // means a *label* column holding the words "point"/"polygon" (e.g. a
        // `kind` column) is NOT mistaken for geometry — which would otherwise
        // send `ST_AsGeoJSON('point')` to the server and blow up.
        for kw in ["POINT", "LINESTRING", "POLYGON", "MULTIPOINT",
                   "MULTILINESTRING", "MULTIPOLYGON", "GEOMETRYCOLLECTION"] where u.hasPrefix(kw) {
            let rest = u.dropFirst(kw.count).drop(while: { $0 == " " })
            if rest.first == "(" { return true }
        }
        return false
    }

    /// Returns the geometry column name + a label column (the first other
    /// column) if a majority of a column's sampled values look like WKT.
    static func detect(_ page: RowsFetcher.Page) -> (geom: String, label: String?)? {
        for (i, col) in page.columns.enumerated() {
            let samples = page.rows.prefix(25).compactMap { $0.indices.contains(i) ? $0[i] : nil }
            guard !samples.isEmpty else { continue }
            let hits = samples.filter(looksLikeGeometry).count
            if hits >= max(1, (samples.count + 1) / 2) {
                let label = page.columns.enumerated().first { $0.offset != i }?.element.name
                return (col.name, label)
            }
        }
        return nil
    }
}

/// One renderable feature: a label plus a single simple geometry. Multi-part
/// GeoJSON geometries are flattened into several features at parse time.
struct SpatialFeature: Identifiable {
    let id = UUID()
    let label: String
    let geom: SimpleGeom
}

enum SimpleGeom {
    case point(CLLocationCoordinate2D)
    case line([CLLocationCoordinate2D])
    case polygon([CLLocationCoordinate2D])   // outer ring

    var coordinates: [CLLocationCoordinate2D] {
        switch self {
        case .point(let c): return [c]
        case .line(let cs): return cs
        case .polygon(let cs): return cs
        }
    }
}

/// Minimal GeoJSON-geometry reader. Returns flattened simple geometries
/// (multi-* and GeometryCollection expand to several).
enum GeoJSON {
    static func parse(_ json: String) -> [SimpleGeom] {
        guard let data = json.data(using: .utf8),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else { return [] }
        return geoms(from: obj)
    }

    private static func geoms(from obj: [String: Any]) -> [SimpleGeom] {
        guard let type = obj["type"] as? String else { return [] }
        switch type {
        case "Point":
            return coord(obj["coordinates"]).map { [.point($0)] } ?? []
        case "LineString":
            return [.line(coords(obj["coordinates"]))]
        case "Polygon":
            guard let rings = obj["coordinates"] as? [Any], let outer = rings.first else { return [] }
            return [.polygon(coords(outer))]
        case "MultiPoint":
            return coords(obj["coordinates"]).map { .point($0) }
        case "MultiLineString":
            return (obj["coordinates"] as? [Any])?.map { .line(coords($0)) } ?? []
        case "MultiPolygon":
            return (obj["coordinates"] as? [Any])?.compactMap { poly in
                (poly as? [Any])?.first.map { .polygon(coords($0)) }
            } ?? []
        case "GeometryCollection":
            return (obj["geometries"] as? [[String: Any]])?.flatMap { geoms(from: $0) } ?? []
        default:
            return []
        }
    }

    private static func coord(_ any: Any?) -> CLLocationCoordinate2D? {
        guard let arr = any as? [Any], arr.count >= 2,
              let lon = (arr[0] as? NSNumber)?.doubleValue,
              let lat = (arr[1] as? NSNumber)?.doubleValue
        else { return nil }
        return CLLocationCoordinate2D(latitude: lat, longitude: lon)
    }

    private static func coords(_ any: Any?) -> [CLLocationCoordinate2D] {
        (any as? [Any])?.compactMap { coord($0) } ?? []
    }
}
