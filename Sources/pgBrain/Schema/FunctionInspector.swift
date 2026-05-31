import Foundation
import PostgresNIO

/// Loads the editable definition of a single function/procedure and the
/// list of input parameters used by the "Run function" sheet. The function
/// designer uses `fetch` to round-trip a function through structured fields
/// (body + signature + options); the runner uses `parameters` to build a
/// call form.
///
/// Overloads are resolved by matching `pg_get_function_arguments(oid)` against
/// the pretty argument string we already carry on `FunctionNode.arguments`
/// (sans the wrapping parentheses), so the right overload is picked even when
/// two functions share a name.
enum FunctionInspector {
    /// Everything the designer needs to reconstruct a `CREATE OR REPLACE`.
    struct Definition: Sendable {
        var language: String
        var returnType: String          // pg_get_function_result — empty for procedures
        var arguments: String           // pg_get_function_arguments (with DEFAULTs)
        var identityArguments: String   // pg_get_function_identity_arguments (for DROP)
        var body: String                // prosrc — empty for SQL-standard BEGIN ATOMIC bodies
        var volatility: Volatility
        var isStrict: Bool
        var securityDefiner: Bool
        var kind: FunctionNode.Kind
        /// True when the routine carries only attributes the structured editor
        /// models. When false (SET clauses, LEAKPROOF, custom COST/ROWS, a
        /// parallel mode, or a SQL-standard body with no `prosrc`), the designer
        /// edits the full `pg_get_functiondef` text instead, so nothing is lost.
        var isStructurallySimple: Bool
    }

    enum Volatility: String, Sendable, CaseIterable, Identifiable {
        case volatile = "VOLATILE"
        case stable = "STABLE"
        case immutable = "IMMUTABLE"
        var id: String { rawValue }
        init(proChar: String) {
            switch proChar {
            case "i": self = .immutable
            case "s": self = .stable
            default:  self = .volatile
            }
        }
    }

    /// One callable input parameter (IN / INOUT / VARIADIC).
    struct Parameter: Sendable, Identifiable {
        let id = UUID()
        var name: String          // "" for positional/unnamed args
        var type: String          // display label (data_type, or udt_name when user-defined)
        var mode: String          // IN / INOUT / VARIADIC
        var hasDefault: Bool
        var defaultExpr: String?
    }

    enum InspectorError: LocalizedError {
        case notConnected
        case notFound
        var errorDescription: String? {
            switch self {
            case .notConnected: return "Not connected."
            case .notFound:     return "Function not found — it may have been dropped."
            }
        }
    }

    static func fetch(client: PostgresClient, function fn: FunctionNode) async throws -> Definition {
        let argsInner = stripParens(fn.arguments)
        let sql: PostgresQuery = """
        SELECT l.lanname,
               pg_get_function_result(p.oid),
               pg_get_function_arguments(p.oid),
               pg_get_function_identity_arguments(p.oid),
               p.provolatile::text,
               p.proisstrict,
               p.prosecdef,
               p.prokind::text,
               COALESCE(p.prosrc, ''),
               (p.proconfig IS NULL
                  AND NOT p.proleakproof
                  AND p.proparallel = 'u'
                  AND p.procost = 100
                  AND (p.proretset = false OR p.prorows = 1000)
                  AND COALESCE(p.prosrc, '') <> '') AS simple
        FROM pg_proc p
        JOIN pg_namespace n ON n.oid = p.pronamespace
        JOIN pg_language l ON l.oid = p.prolang
        WHERE n.nspname = \(fn.schema) AND p.proname = \(fn.name)
          AND pg_get_function_arguments(p.oid) = \(argsInner)
        LIMIT 1
        """
        let rows = try await client.query(sql)
        for try await (lang, ret, args, idargs, vol, strict, secdef, kindChar, src, simple)
            in rows.decode((String, String?, String, String, String, Bool, Bool, String, String, Bool).self) {
            let kind: FunctionNode.Kind
            switch kindChar {
            case "p": kind = .procedure
            case "a": kind = .aggregate
            case "w": kind = .window
            default:  kind = .function
            }
            return Definition(
                language: lang,
                returnType: ret ?? "",
                arguments: args,
                identityArguments: idargs,
                body: src,
                volatility: Volatility(proChar: vol),
                isStrict: strict,
                securityDefiner: secdef,
                kind: kind,
                isStructurallySimple: simple
            )
        }
        throw InspectorError.notFound
    }

    /// Input parameters for the run/call form, in declaration order.
    static func parameters(client: PostgresClient, function fn: FunctionNode) async throws -> [Parameter] {
        let argsInner = stripParens(fn.arguments)
        let sql: PostgresQuery = """
        SELECT COALESCE(par.parameter_name, ''),
               par.parameter_mode,
               par.data_type,
               par.udt_name,
               par.parameter_default
        FROM pg_proc p
        JOIN pg_namespace n ON n.oid = p.pronamespace
        JOIN information_schema.parameters par
          ON par.specific_schema = n.nspname
         AND par.specific_name = p.proname || '_' || p.oid
        WHERE n.nspname = \(fn.schema) AND p.proname = \(fn.name)
          AND pg_get_function_arguments(p.oid) = \(argsInner)
          AND par.parameter_mode IN ('IN','INOUT','VARIADIC')
        ORDER BY par.ordinal_position
        """
        let rows = try await client.query(sql)
        var out: [Parameter] = []
        for try await (name, mode, dataType, udtName, def)
            in rows.decode((String, String, String, String, String?).self) {
            // data_type is "USER-DEFINED" / "ARRAY" for non-builtins; udt_name
            // carries the real name there, so prefer it in those cases.
            let label = (dataType == "USER-DEFINED" || dataType == "ARRAY") ? udtName : dataType
            out.append(Parameter(
                name: name,
                type: label,
                mode: mode,
                hasDefault: def != nil,
                defaultExpr: def
            ))
        }
        return out
    }

    private static func stripParens(_ s: String) -> String {
        var t = s.trimmingCharacters(in: .whitespaces)
        if t.hasPrefix("(") { t.removeFirst() }
        if t.hasSuffix(")") { t.removeLast() }
        return t
    }
}
