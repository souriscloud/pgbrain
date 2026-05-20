import Foundation

/// PostgreSQL identifier quoting. We never interpolate identifiers via
/// parameter binding (the protocol doesn't allow it) so this is the single
/// chokepoint that keeps generated SQL safe.
enum SQLIdent {
    static func quote(_ ident: String) -> String {
        "\"" + ident.replacingOccurrences(of: "\"", with: "\"\"") + "\""
    }

    static func qualified(schema: String, name: String) -> String {
        "\(quote(schema)).\(quote(name))"
    }
}
