import Foundation

/// What a typed value-editor produces. The grid write-path and the SQL
/// builders interpret these differently:
///
///   - `.literal`    bound as a parameter, cast server-side to the column type
///   - `.expression` inlined as raw SQL (`now()`, `gen_random_uuid()`, …)
///   - `.null`       SQL `NULL`
///   - `.defaultKeyword` the column's `DEFAULT` (omit from INSERT / `SET col = DEFAULT`)
///
/// This is the single currency every input control in the app speaks, so a
/// date picker, a JSON editor and a boolean toggle all hand back the same
/// thing and the write path stays uniform.
enum TypedInputValue: Equatable, Sendable {
    case literal(String)
    case expression(String)
    case null
    case defaultKeyword

    /// Human-readable text for display in a grid cell / summary chip.
    var displayText: String {
        switch self {
        case .literal(let s): return s
        case .expression(let e): return e
        case .null: return "NULL"
        case .defaultKeyword: return "DEFAULT"
        }
    }

    /// Render as a SQL fragment for hand-built statements (INSERT VALUES,
    /// function args, column defaults). Literals are single-quoted (and
    /// optionally `::type`-cast); expressions inline verbatim; null/default
    /// emit their keywords. `cast: false` suits assignment contexts (a
    /// function arg coerces an unknown-typed literal to the parameter type
    /// on its own, and casting to an internal udt name would fail).
    func sqlFragment(typeName: String, cast: Bool = true) -> String {
        switch self {
        case .null:               return "NULL"
        case .defaultKeyword:     return "DEFAULT"
        case .expression(let e):  return e
        case .literal(let s):
            let quoted = "'" + s.replacingOccurrences(of: "'", with: "''") + "'"
            return cast ? "\(quoted)::\(typeName)" : quoted
        }
    }

    /// True when this is a plain literal equal to `other` literal/null — used
    /// to detect no-op edits against a cell's server value.
    func isNoOp(against original: String?) -> Bool {
        switch self {
        case .literal(let s): return s == original
        case .null: return original == nil
        case .expression, .defaultKeyword: return false
        }
    }
}

/// Rich, editor-facing classification of a Postgres type. Deliberately
/// separate from `ColumnTypeKind` (whose exhaustive `switch`es power the
/// grid renderer, exporter and profiler) so the input family can grow new
/// categories — time, enum, interval, network, array, geometry — without
/// rippling into every consumer of the display path.
enum InputKind: Equatable, Sendable {
    case text
    case integer
    case decimal
    case boolean
    case date
    case time
    case timestamp(tz: Bool)
    case json
    case uuid
    case bytes
    case enumType([String])
    case interval
    case network
    case array(elementType: String)
    case geometry
    case unknown

    /// Resolve from a `format_type()` string plus the connection's enum
    /// catalog (`bare name` / `schema.name` → labels). Modifiers like
    /// `(255)` / `(10,2)` are tolerated; array `[]` suffixes are peeled.
    static func resolve(typeName raw: String, enums: [String: [String]] = [:]) -> InputKind {
        let trimmed = raw.trimmingCharacters(in: .whitespaces)
        let lower = trimmed.lowercased()

        // Array: "integer[]", "text[]", "numeric(10,2)[]" → editor offers a
        // literal `{…}` field with the element type as a hint.
        if lower.hasSuffix("[]") {
            let element = String(trimmed.dropLast(2))
            return .array(elementType: element)
        }

        // Strip a trailing type modifier "(...)" for keyword matching, but
        // keep the original around for enum lookup (enums never carry one).
        let base = lower.contains("(") ? String(lower[..<lower.firstIndex(of: "(")!]) : lower
        let baseTrimmed = base.trimmingCharacters(in: .whitespaces)

        switch baseTrimmed {
        case "text", "name", "citext", "char", "bpchar", "character",
             "character varying", "varchar", "xml":
            return .text
        case "smallint", "integer", "bigint", "int2", "int4", "int8", "oid",
             "smallserial", "serial", "bigserial":
            return .integer
        case "real", "double precision", "float4", "float8", "numeric",
             "decimal", "money":
            return .decimal
        case "boolean", "bool":
            return .boolean
        case "date":
            return .date
        case "time", "time without time zone", "time with time zone", "timetz":
            return .time
        case "timestamp", "timestamp without time zone":
            return .timestamp(tz: false)
        case "timestamp with time zone", "timestamptz":
            return .timestamp(tz: true)
        case "json", "jsonb":
            return .json
        case "uuid":
            return .uuid
        case "bytea":
            return .bytes
        case "interval":
            return .interval
        case "inet", "cidr", "macaddr", "macaddr8":
            return .network
        case "geometry", "geography":
            return .geometry
        default:
            break
        }

        // Enum types surface under their bare name (e.g. "mood") or
        // schema-qualified ("public.mood"). Match either.
        if let labels = enums[trimmed] ?? enums[lower]
            ?? enums[trimmed.components(separatedBy: ".").last ?? trimmed] {
            return .enumType(labels)
        }
        return .unknown
    }

    /// SF Symbol used by the type chip — keeps the family visually legible.
    var symbol: String {
        switch self {
        case .text:               return "textformat"
        case .integer:            return "number"
        case .decimal:            return "number.square"
        case .boolean:            return "switch.2"
        case .date:               return "calendar"
        case .time:               return "clock"
        case .timestamp:          return "calendar.badge.clock"
        case .json:               return "curlybraces"
        case .uuid:               return "number.circle"
        case .bytes:              return "doc.badge.gearshape"
        case .enumType:           return "list.bullet.circle"
        case .interval:           return "timer"
        case .network:            return "network"
        case .array:              return "square.stack.3d.up"
        case .geometry:           return "map"
        case .unknown:            return "questionmark.circle"
        }
    }
}

/// Quick-action expressions offered per type in the editor's mode menu.
/// Each pairs a label with the raw SQL inlined when chosen.
struct TypedQuickAction: Identifiable, Equatable {
    let id = UUID()
    let label: String
    let symbol: String
    let expression: String

    static func actions(for kind: InputKind) -> [TypedQuickAction] {
        switch kind {
        case .timestamp:
            return [
                .init(label: "now()", symbol: "clock", expression: "now()"),
                .init(label: "Start of today", symbol: "sunrise", expression: "date_trunc('day', now())"),
            ]
        case .date:
            return [
                .init(label: "today", symbol: "calendar", expression: "current_date"),
            ]
        case .time:
            return [
                .init(label: "now", symbol: "clock", expression: "current_time"),
            ]
        case .uuid:
            return [
                .init(label: "Generate", symbol: "wand.and.stars", expression: "gen_random_uuid()"),
            ]
        default:
            return []
        }
    }
}
