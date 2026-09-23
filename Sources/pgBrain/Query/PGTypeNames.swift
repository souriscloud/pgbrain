import Foundation

/// `format_type()`-compatible names for built-in type OIDs, so result columns
/// get the same labels the catalog uses (and `ColumnTypeKind` buckets them)
/// without a round trip. OIDs of built-ins are fixed across PG versions.
enum PGTypeNames {
    static let builtin: [UInt32: String] = [
        16: "boolean", 17: "bytea", 18: "\"char\"", 19: "name", 20: "bigint",
        21: "smallint", 22: "int2vector", 23: "integer", 24: "regproc", 25: "text",
        26: "oid", 27: "tid", 28: "xid", 29: "cid", 30: "oidvector",
        114: "json", 142: "xml", 194: "pg_node_tree", 600: "point", 601: "lseg",
        602: "path", 603: "box", 604: "polygon", 628: "line", 650: "cidr",
        700: "real", 701: "double precision", 705: "unknown", 718: "circle",
        774: "macaddr8", 790: "money", 829: "macaddr", 869: "inet",
        1033: "aclitem", 1042: "character", 1043: "character varying",
        1082: "date", 1083: "time without time zone",
        1114: "timestamp without time zone", 1184: "timestamp with time zone",
        1186: "interval", 1266: "time with time zone", 1560: "bit",
        1562: "bit varying", 1700: "numeric", 1790: "refcursor",
        2202: "regprocedure", 2203: "regoper", 2204: "regoperator",
        2205: "regclass", 2206: "regtype", 2249: "record", 2275: "cstring",
        2278: "void", 2950: "uuid", 3220: "pg_lsn", 3614: "tsvector",
        3615: "tsquery", 3734: "regconfig", 3769: "regdictionary", 3802: "jsonb",
        3904: "int4range", 3906: "numrange", 3908: "tsrange", 3910: "tstzrange",
        3912: "daterange", 3926: "int8range", 4072: "jsonpath",
        4089: "regnamespace", 4096: "regrole", 4191: "regcollation",
        5038: "pg_snapshot", 5069: "xid8",
        4451: "int4multirange", 4532: "nummultirange", 4533: "tsmultirange",
        4534: "tstzmultirange", 4535: "datemultirange", 4536: "int8multirange",
        143: "xml[]", 199: "json[]", 651: "cidr[]", 791: "money[]",
        1000: "boolean[]", 1001: "bytea[]", 1002: "\"char\"[]", 1003: "name[]",
        1005: "smallint[]", 1007: "integer[]", 1009: "text[]", 1014: "character[]",
        1015: "character varying[]", 1016: "bigint[]", 1017: "point[]",
        1021: "real[]", 1022: "double precision[]", 1028: "oid[]",
        1034: "aclitem[]", 1040: "macaddr[]", 1041: "inet[]",
        1115: "timestamp without time zone[]", 1182: "date[]",
        1183: "time without time zone[]", 1185: "timestamp with time zone[]",
        1187: "interval[]", 1231: "numeric[]", 1270: "time with time zone[]",
        1561: "bit[]", 1563: "bit varying[]", 2951: "uuid[]", 3807: "jsonb[]",
        2287: "record[]", 1263: "cstring[]",
    ]

    /// Name for a built-in OID including the typmod where `format_type` would
    /// show one for the common cases; nil for anything not built in.
    static func name(oid: UInt32, typmod: Int32) -> String? {
        guard let base = builtin[oid] else { return nil }
        guard typmod >= 0 else { return base }
        switch oid {
        case 1043, 1042:
            return typmod >= 4 ? "\(base)(\(typmod - 4))" : base
        case 1700:
            guard typmod >= 4 else { return base }
            let packed = typmod - 4
            return "numeric(\((packed >> 16) & 0xFFFF),\(packed & 0xFFFF))"
        default:
            return base
        }
    }
}
