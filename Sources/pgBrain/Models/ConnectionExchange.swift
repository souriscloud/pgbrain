import Foundation

/// One-click exporters + paste-importer for `Connection`. Backs the
/// "Copy as" submenu in Welcome and the Connection editor's
/// `Import from clipboard` button.
///
/// Formats:
///   - `.laravelEnv`    — `DB_HOST=…` block, paste into `.env`
///   - `.laravelVault`  — JSON object with `DB_*` keys, paste into a
///                        Laravel Vault secret
///   - `.connectionURL` — `postgres://user:pass@host:port/db?sslmode=…`
///   - `.pgbrain`       — canonical JSON understood by the new-
///                        connection sheet's `⌘V` import path. Tagged
///                        with `"pgbrain.connection": "v1"` so paste
///                        detection doesn't false-match on bare JSON.
@MainActor
enum ConnectionExchange {
    enum Format: String, CaseIterable, Identifiable {
        case laravelEnv
        case laravelVault
        case connectionURL
        case pgbrain

        var id: String { rawValue }

        var label: String {
            switch self {
            case .laravelEnv:    "Laravel .env"
            case .laravelVault:  "Laravel Vault JSON"
            case .connectionURL: "Connection URL"
            case .pgbrain:       "pgBrain Exchange"
            }
        }
    }

    /// Build the requested representation. `includePassword: false`
    /// (the default) omits the password — copy-paste into a chat /
    /// shared doc / VCS shouldn't carry secrets unless the user opts
    /// in (Settings or a Shift-modified menu item).
    static func render(_ connection: Connection, format: Format, includePassword: Bool = false) -> String {
        let password = includePassword ? (Keychain.password(for: connection.id) ?? "") : ""
        switch format {
        case .laravelEnv:    return renderLaravelEnv(connection, password: password)
        case .laravelVault:  return renderLaravelVault(connection, password: password)
        case .connectionURL: return renderURL(connection, password: password)
        case .pgbrain:       return renderPGBrain(connection, password: includePassword ? password : nil)
        }
    }

    // MARK: - Per-format

    private static func renderLaravelEnv(_ c: Connection, password: String) -> String {
        // Standard Laravel keys (DB_USERNAME, not DB_USER — Laravel's
        // database.php reads DB_USERNAME).
        var lines: [String] = []
        lines.append("DB_CONNECTION=pgsql")
        lines.append("DB_HOST=\(envEscape(c.host))")
        lines.append("DB_PORT=\(c.port)")
        lines.append("DB_DATABASE=\(envEscape(c.database))")
        lines.append("DB_USERNAME=\(envEscape(c.username))")
        lines.append("DB_PASSWORD=\(envEscape(password))")
        if c.sslMode != .prefer {
            lines.append("DB_SSLMODE=\(c.sslMode.rawValue)")
        }
        return lines.joined(separator: "\n") + "\n"
    }

    private static func renderLaravelVault(_ c: Connection, password: String) -> String {
        // Laravel Vault stores secrets as a flat JSON object — same
        // keys as .env, pretty-printed two-space indent.
        var pairs: [(String, String)] = [
            ("DB_CONNECTION", "pgsql"),
            ("DB_HOST", c.host),
            ("DB_PORT", String(c.port)),
            ("DB_DATABASE", c.database),
            ("DB_USERNAME", c.username),
            ("DB_PASSWORD", password),
        ]
        if c.sslMode != .prefer {
            pairs.append(("DB_SSLMODE", c.sslMode.rawValue))
        }
        let body = pairs.map { (k, v) in
            "  \(jsonString(k)): \(jsonString(v))"
        }.joined(separator: ",\n")
        return "{\n\(body)\n}\n"
    }

    private static func renderURL(_ c: Connection, password: String) -> String {
        // `postgres://user:pass@host:port/database?sslmode=…`. URL-encode
        // user, password, and database since they can contain
        // `@`, `/`, `:`, etc.
        let safe = CharacterSet.urlPasswordAllowed.subtracting(.init(charactersIn: "@:/?#"))
        func enc(_ s: String) -> String {
            s.addingPercentEncoding(withAllowedCharacters: safe) ?? s
        }
        var url = "postgres://"
        let hasUser = !c.username.isEmpty
        if hasUser {
            url += enc(c.username)
            if !password.isEmpty { url += ":\(enc(password))" }
            url += "@"
        }
        url += c.host
        if c.port != 5432 { url += ":\(c.port)" }
        url += "/"
        if !c.database.isEmpty { url += enc(c.database) }
        if c.sslMode != .prefer {
            url += "?sslmode=\(c.sslMode.rawValue)"
        }
        return url
    }

    /// pgBrain's own exchange format — the inverse of `parse(...)`.
    private static func renderPGBrain(_ c: Connection, password: String?) -> String {
        var payload: [String: Any] = [
            "pgbrain.connection": "v1",
            "name": c.name,
            "host": c.host,
            "port": c.port,
            "database": c.database,
            "username": c.username,
            "sslMode": c.sslMode.rawValue,
            "isProduction": c.isProduction,
            "colorTag": c.colorTag.rawValue,
        ]
        if let pw = password, !pw.isEmpty {
            payload["password"] = pw
        }
        guard let data = try? JSONSerialization.data(
            withJSONObject: payload,
            options: [.prettyPrinted, .sortedKeys]
        ), let s = String(data: data, encoding: .utf8) else {
            return ""
        }
        return s + "\n"
    }

    // MARK: - Paste import

    struct Imported {
        let connection: Connection
        /// Plain-text password if present in the payload — caller
        /// stashes it into the Keychain after saving the connection.
        let password: String?
    }

    /// Inverse of `renderPGBrain`. Returns nil for any input that
    /// doesn't carry the `"pgbrain.connection"` magic — keeps us from
    /// false-matching arbitrary JSON on the clipboard.
    static func parse(_ raw: String) -> Imported? {
        guard let data = raw.data(using: .utf8),
              let obj = try? JSONSerialization.jsonObject(with: data, options: []) as? [String: Any],
              let version = obj["pgbrain.connection"] as? String,
              version == "v1"
        else { return nil }

        var c = Connection(name: (obj["name"] as? String) ?? "Imported connection")
        if let v = obj["host"] as? String { c.host = v }
        if let v = obj["port"] as? Int { c.port = v }
        if let v = obj["database"] as? String { c.database = v }
        if let v = obj["username"] as? String { c.username = v }
        if let v = obj["sslMode"] as? String, let m = Connection.SSLMode(rawValue: v) {
            c.sslMode = m
        }
        if let v = obj["isProduction"] as? Bool { c.isProduction = v }
        if let v = obj["colorTag"] as? String, let tag = Connection.ColorTag(rawValue: v) {
            c.colorTag = tag
        }
        let password = obj["password"] as? String
        return Imported(connection: c, password: password)
    }

    // MARK: - Helpers

    /// Quote .env values that contain spaces, quotes, or hashes.
    /// Bare values otherwise — keeps the output readable when nothing
    /// fancy is needed.
    private static func envEscape(_ value: String) -> String {
        if value.isEmpty { return "" }
        let needsQuotes = value.contains(where: { $0 == " " || $0 == "\"" || $0 == "#" || $0 == "$" })
        guard needsQuotes else { return value }
        let escaped = value
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
        return "\"\(escaped)\""
    }

    private static func jsonString(_ value: String) -> String {
        guard let data = try? JSONSerialization.data(
            withJSONObject: [value], options: []
        ), let s = String(data: data, encoding: .utf8) else { return "\"\(value)\"" }
        // JSONSerialization wraps the string in an array; strip [ ].
        let trimmed = s.trimmingCharacters(in: CharacterSet(charactersIn: "[]"))
        return trimmed
    }
}
