import Foundation

/// Parsers for the libpq connection formats users already have lying around:
/// `postgres://` URIs, `key=value` conninfo strings, `~/.pgpass` and
/// `~/.pg_service.conf`. Pure and nonisolated so they're unit-testable.
enum ConnInfoParser {
    /// Everything a conninfo can say that pgBrain understands. `nil` = not
    /// specified, so applying it leaves the connection's field untouched.
    struct Parsed: Equatable {
        var host: String?
        var port: Int?
        var database: String?
        var user: String?
        var password: String?
        var sslMode: Connection.SSLMode?
        var sslRootCert: String?
        var sslCert: String?
        var sslKey: String?
        var applicationName: String?
        var service: String?
        var statementTimeoutSeconds: Int?
        var idleInTransactionTimeoutSeconds: Int?
        var readOnly: Bool?
        /// Keys pgBrain ignores (e.g. `connect_timeout`), kept so the UI can
        /// mention them.
        var ignored: [String: String] = [:]
    }

    enum ParseError: LocalizedError, Equatable {
        case empty
        case unrecognised
        case malformed(String)

        var errorDescription: String? {
            switch self {
            case .empty: return "Nothing to parse."
            case .unrecognised: return "Not a postgres:// URL or a key=value connection string."
            case .malformed(let why): return "Couldn't parse the connection string: \(why)"
            }
        }
    }

    // MARK: - Entry point

    static func parse(_ raw: String) throws -> Parsed {
        let text = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { throw ParseError.empty }
        let lower = text.lowercased()
        if lower.hasPrefix("postgres://") || lower.hasPrefix("postgresql://") {
            return try parseURI(text)
        }
        if text.contains("=") {
            return try parseKeyValue(text)
        }
        throw ParseError.unrecognised
    }

    // MARK: - URI

    static func parseURI(_ raw: String) throws -> Parsed {
        let text = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let schemeEnd = text.range(of: "://") else { throw ParseError.unrecognised }
        var rest = String(text[schemeEnd.upperBound...])
        if let hash = rest.firstIndex(of: "#") { rest = String(rest[..<hash]) }

        var query = ""
        if let q = rest.firstIndex(of: "?") {
            query = String(rest[rest.index(after: q)...])
            rest = String(rest[..<q])
        }
        var path: String?
        if let slash = rest.firstIndex(of: "/") {
            path = String(rest[rest.index(after: slash)...])
            rest = String(rest[..<slash])
        }

        var p = Parsed()
        var netloc = rest
        if let at = netloc.lastIndex(of: "@") {
            let userinfo = String(netloc[..<at])
            netloc = String(netloc[netloc.index(after: at)...])
            if let colon = userinfo.firstIndex(of: ":") {
                p.user = try decode(String(userinfo[..<colon]))
                p.password = try decode(String(userinfo[userinfo.index(after: colon)...]))
            } else if !userinfo.isEmpty {
                p.user = try decode(userinfo)
            }
        }
        // Multi-host URIs (`h1:5432,h2:5433`) — pgBrain connects to one
        // host, the first.
        let firstHost = netloc.split(separator: ",", omittingEmptySubsequences: false).first.map(String.init) ?? ""
        let (host, port) = try splitHostPort(firstHost)
        if let host, !host.isEmpty { p.host = try decode(host) }
        if let port { p.port = port }
        if let path, !path.isEmpty { p.database = try decode(path) }

        for pair in query.split(separator: "&") where !pair.isEmpty {
            let parts = pair.split(separator: "=", maxSplits: 1, omittingEmptySubsequences: false)
            let key = try decode(String(parts[0]))
            let value = parts.count > 1 ? try decode(String(parts[1])) : ""
            try apply(key: key, value: value, to: &p)
        }
        return p
    }

    private static func decode(_ s: String) throws -> String {
        guard let d = s.removingPercentEncoding else {
            throw ParseError.malformed("bad percent-encoding in \"\(s)\"")
        }
        return d
    }

    private static func splitHostPort(_ s: String) throws -> (String?, Int?) {
        if s.isEmpty { return (nil, nil) }
        if s.hasPrefix("[") {
            guard let close = s.firstIndex(of: "]") else { throw ParseError.malformed("unterminated IPv6 address") }
            let host = String(s[s.index(after: s.startIndex)..<close])
            let after = s[s.index(after: close)...]
            if after.hasPrefix(":") {
                return (host, try port(String(after.dropFirst())))
            }
            return (host, nil)
        }
        if let colon = s.lastIndex(of: ":") {
            let host = String(s[..<colon])
            let portText = String(s[s.index(after: colon)...])
            return (host.isEmpty ? nil : host, portText.isEmpty ? nil : try port(portText))
        }
        return (s, nil)
    }

    private static func port(_ s: String) throws -> Int {
        guard let n = Int(s), (1...65_535).contains(n) else { throw ParseError.malformed("invalid port \"\(s)\"") }
        return n
    }

    // MARK: - key=value

    static func parseKeyValue(_ raw: String) throws -> Parsed {
        var p = Parsed()
        let chars = Array(raw)
        var i = 0
        func skipSpace() { while i < chars.count, chars[i].isWhitespace { i += 1 } }

        while true {
            skipSpace()
            if i >= chars.count { break }
            var key = ""
            while i < chars.count, chars[i] != "=", !chars[i].isWhitespace {
                key.append(chars[i]); i += 1
            }
            skipSpace()
            guard i < chars.count, chars[i] == "=" else {
                throw ParseError.malformed("missing \"=\" after \"\(key)\"")
            }
            i += 1
            skipSpace()
            var value = ""
            if i < chars.count, chars[i] == "'" {
                i += 1
                var closed = false
                while i < chars.count {
                    let ch = chars[i]
                    if ch == "\\", i + 1 < chars.count {
                        value.append(chars[i + 1]); i += 2; continue
                    }
                    if ch == "'" { closed = true; i += 1; break }
                    value.append(ch); i += 1
                }
                guard closed else { throw ParseError.malformed("unterminated quoted value for \"\(key)\"") }
            } else {
                while i < chars.count, !chars[i].isWhitespace {
                    if chars[i] == "\\", i + 1 < chars.count {
                        value.append(chars[i + 1]); i += 2; continue
                    }
                    value.append(chars[i]); i += 1
                }
            }
            guard !key.isEmpty else { throw ParseError.malformed("empty key") }
            try apply(key: key, value: value, to: &p)
        }
        return p
    }

    // MARK: - Shared key mapping

    private static func apply(key: String, value: String, to p: inout Parsed) throws {
        switch key.lowercased() {
        case "host":
            p.host = value.split(separator: ",").first.map(String.init) ?? value
        case "hostaddr":
            if p.host == nil { p.host = value.split(separator: ",").first.map(String.init) ?? value }
        case "port":
            if let first = value.split(separator: ",").first { p.port = try port(String(first)) }
        case "dbname", "database":
            p.database = value
        case "user", "username":
            p.user = value
        case "password":
            p.password = value
        case "sslmode":
            guard let mode = Connection.SSLMode(rawValue: value.lowercased()) else {
                throw ParseError.malformed("unknown sslmode \"\(value)\"")
            }
            p.sslMode = mode
        case "sslrootcert":
            p.sslRootCert = value
        case "sslcert":
            p.sslCert = value
        case "sslkey":
            p.sslKey = value
        case "application_name":
            p.applicationName = value
        case "service":
            p.service = value
        case "options":
            applyOptions(value, to: &p)
        default:
            p.ignored[key] = value
        }
    }

    /// `options='-c statement_timeout=5s -c default_transaction_read_only=on'`.
    private static func applyOptions(_ options: String, to p: inout Parsed) {
        let tokens = options.split(whereSeparator: \.isWhitespace).map(String.init)
        var settings: [String] = []
        var i = 0
        while i < tokens.count {
            let t = tokens[i]
            if t == "-c", i + 1 < tokens.count {
                settings.append(tokens[i + 1]); i += 2; continue
            }
            if t.hasPrefix("-c") { settings.append(String(t.dropFirst(2))) }
            else if t.hasPrefix("--") { settings.append(String(t.dropFirst(2))) }
            i += 1
        }
        for setting in settings {
            let kv = setting.split(separator: "=", maxSplits: 1).map(String.init)
            guard kv.count == 2 else { continue }
            let name = kv[0].lowercased().replacingOccurrences(of: "-", with: "_")
            switch name {
            case "statement_timeout":
                p.statementTimeoutSeconds = durationSeconds(kv[1])
            case "idle_in_transaction_session_timeout":
                p.idleInTransactionTimeoutSeconds = durationSeconds(kv[1])
            case "default_transaction_read_only":
                p.readOnly = ["on", "true", "1", "yes"].contains(kv[1].lowercased())
            default:
                p.ignored["options:\(name)"] = kv[1]
            }
        }
    }

    /// Postgres duration GUC → whole seconds (rounded up). A bare number is
    /// milliseconds, as the server reads it for these settings.
    static func durationSeconds(_ raw: String) -> Int? {
        let s = raw.trimmingCharacters(in: .whitespaces).lowercased()
        let digits = s.prefix { $0.isNumber || $0 == "." }
        guard let n = Double(digits) else { return nil }
        let unit = s.dropFirst(digits.count).trimmingCharacters(in: .whitespaces)
        let ms: Double
        switch unit {
        case "", "ms": ms = n
        case "s": ms = n * 1_000
        case "min": ms = n * 60_000
        case "h": ms = n * 3_600_000
        case "d": ms = n * 86_400_000
        default: return nil
        }
        return Int((ms / 1_000).rounded(.up))
    }

    // MARK: - Apply to a Connection

    /// Copy every specified field onto `connection`; returns the password
    /// (if the input carried one) for the caller to put in the Keychain.
    @discardableResult
    static func apply(_ p: Parsed, to c: inout Connection) -> String? {
        if let host = p.host {
            // Unix-socket directories — pgBrain speaks TCP only.
            c.host = host.hasPrefix("/") ? "localhost" : host
        }
        if let port = p.port { c.port = port }
        if let db = p.database { c.database = db }
        if let user = p.user { c.username = user }
        if let mode = p.sslMode { c.sslMode = mode }
        if let v = p.sslRootCert { c.sslRootCertPath = v }
        if let v = p.sslCert { c.sslClientCertPath = v }
        if let v = p.sslKey { c.sslClientKeyPath = v }
        if let v = p.statementTimeoutSeconds { c.statementTimeoutSeconds = v }
        if let v = p.idleInTransactionTimeoutSeconds { c.idleInTransactionTimeoutSeconds = v }
        if let v = p.readOnly { c.readOnly = v }
        return p.password
    }

    // MARK: - ~/.pgpass

    struct PgPassEntry: Equatable {
        var host: String
        var port: String
        var database: String
        var user: String
        var password: String
    }

    /// `hostname:port:database:username:password`, `\` escapes `:` and `\`,
    /// `#` starts a comment line. Malformed lines are skipped, as libpq does.
    static func parsePgPass(_ text: String) -> [PgPassEntry] {
        var out: [PgPassEntry] = []
        for rawLine in text.split(omittingEmptySubsequences: true, whereSeparator: \.isNewline) {
            let line = String(rawLine)
            if line.hasPrefix("#") || line.trimmingCharacters(in: .whitespaces).isEmpty { continue }
            var fields: [String] = []
            var current = ""
            var escaped = false
            for ch in line {
                if escaped { current.append(ch); escaped = false; continue }
                if ch == "\\" { escaped = true; continue }
                if ch == ":" && fields.count < 4 { fields.append(current); current = ""; continue }
                current.append(ch)
            }
            fields.append(current)
            guard fields.count == 5 else { continue }
            out.append(PgPassEntry(host: fields[0], port: fields[1], database: fields[2],
                                   user: fields[3], password: fields[4]))
        }
        return out
    }

    /// First matching entry wins, `*` matches anything — libpq's rules.
    static func pgpassLookup(_ entries: [PgPassEntry], host: String, port: Int,
                             database: String, user: String) -> String? {
        func match(_ field: String, _ value: String) -> Bool { field == "*" || field == value }
        return entries.first {
            match($0.host, host) && match($0.port, String(port))
                && match($0.database, database) && match($0.user, user)
        }?.password
    }

    // MARK: - ~/.pg_service.conf

    struct ServiceEntry: Equatable {
        var name: String
        var parsed: Parsed
    }

    /// INI-style: `[service]` headers followed by `key=value` lines.
    static func parseServiceFile(_ text: String) -> [ServiceEntry] {
        var out: [ServiceEntry] = []
        var current: ServiceEntry?
        for rawLine in text.split(omittingEmptySubsequences: true, whereSeparator: \.isNewline) {
            let line = rawLine.trimmingCharacters(in: .whitespaces)
            if line.isEmpty || line.hasPrefix("#") || line.hasPrefix(";") { continue }
            if line.hasPrefix("["), line.hasSuffix("]") {
                if let current { out.append(current) }
                current = ServiceEntry(name: String(line.dropFirst().dropLast()), parsed: Parsed())
                continue
            }
            guard var entry = current,
                  let eq = line.firstIndex(of: "=") else { continue }
            let key = line[..<eq].trimmingCharacters(in: .whitespaces)
            let value = line[line.index(after: eq)...].trimmingCharacters(in: .whitespaces)
            try? apply(key: key, value: value, to: &entry.parsed)
            current = entry
        }
        if let current { out.append(current) }
        return out
    }

    /// A new connection named after the service, defaults filled in.
    static func connection(from service: ServiceEntry) -> (Connection, String?) {
        var c = Connection(name: service.name, host: "localhost", port: 5432)
        let password = apply(service.parsed, to: &c)
        return (c, password)
    }

    static var defaultPgPassURL: URL {
        if let override = ProcessInfo.processInfo.environment["PGPASSFILE"], !override.isEmpty {
            return URL(fileURLWithPath: override)
        }
        return FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".pgpass")
    }

    static var defaultServiceFileURL: URL {
        if let override = ProcessInfo.processInfo.environment["PGSERVICEFILE"], !override.isEmpty {
            return URL(fileURLWithPath: override)
        }
        return FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".pg_service.conf")
    }
}
