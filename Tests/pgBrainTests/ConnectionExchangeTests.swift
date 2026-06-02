import XCTest
@testable import pgBrain

/// Fast, no-database tests for the connection bundle codec — the export/import
/// path users hit via Welcome's "Import/Export". These run everywhere (no
/// Postgres needed), so the suite stays meaningful on a bare CI box.
@MainActor
final class ConnectionExchangeTests: XCTestCase {

    func testBundleRoundTripPreservesAllFields() throws {
        let original = [
            Connection(name: "Local", host: "localhost", port: 5432,
                       database: "app", username: "dev", sslMode: .prefer,
                       colorTag: .green, isProduction: false),
            Connection(name: "Prod", host: "db.example.com", port: 6432,
                       database: "prod", username: "admin", sslMode: .verifyFull,
                       colorTag: .red, sshEnabled: true, sshHost: "bastion.example.com",
                       sshPort: 2222, sshUser: "tunnel", sshKeyPath: "~/.ssh/id_ed25519",
                       isProduction: true),
        ]

        let json = ConnectionExchange.renderBundle(original, includePasswords: false)
        let parsed = try XCTUnwrap(ConnectionExchange.parseBundle(json),
                                   "rendered bundle should parse back")
        XCTAssertEqual(parsed.count, original.count)

        for (imported, want) in zip(parsed, original) {
            let got = imported.connection
            XCTAssertEqual(got.name, want.name)
            XCTAssertEqual(got.host, want.host)
            XCTAssertEqual(got.port, want.port)
            XCTAssertEqual(got.database, want.database)
            XCTAssertEqual(got.username, want.username)
            XCTAssertEqual(got.sslMode, want.sslMode)
            XCTAssertEqual(got.colorTag, want.colorTag)
            XCTAssertEqual(got.isProduction, want.isProduction)
            XCTAssertEqual(got.sshEnabled, want.sshEnabled)
            XCTAssertEqual(got.sshHost, want.sshHost)
            XCTAssertEqual(got.sshPort, want.sshPort)
            XCTAssertEqual(got.sshUser, want.sshUser)
            XCTAssertEqual(got.sshKeyPath, want.sshKeyPath)
            XCTAssertNil(imported.password, "no password should be emitted when includePasswords is false")
        }
    }

    func testParseRejectsForeignJSON() {
        XCTAssertNil(ConnectionExchange.parseBundle("{\"hello\":\"world\"}"),
                     "arbitrary JSON must not be mistaken for a connection bundle")
        XCTAssertNil(ConnectionExchange.parseBundle("not json at all"))
    }

    func testParseAcceptsSingleV1Object() throws {
        let single = Connection(name: "Solo", host: "h", port: 5433, database: "d", username: "u")
        let json = ConnectionExchange.render(single, format: .pgbrain)
        let parsed = try XCTUnwrap(ConnectionExchange.parseBundle(json))
        XCTAssertEqual(parsed.count, 1)
        XCTAssertEqual(parsed.first?.connection.host, "h")
        XCTAssertEqual(parsed.first?.connection.port, 5433)
    }

    // MARK: render formats

    func testFormatMetadata() {
        XCTAssertEqual(ConnectionExchange.Format.allCases.count, 4)
        for f in ConnectionExchange.Format.allCases {
            XCTAssertFalse(f.label.isEmpty)
            XCTAssertEqual(f.id, f.rawValue)
        }
    }

    func testLaravelEnvRendersStandardKeysAndSslmode() {
        let c = Connection(name: "X", host: "db.example.com", port: 5432,
                           database: "app", username: "dev", sslMode: .require)
        let env = ConnectionExchange.render(c, format: .laravelEnv)
        XCTAssertTrue(env.contains("DB_CONNECTION=pgsql"))
        XCTAssertTrue(env.contains("DB_HOST=db.example.com"))
        XCTAssertTrue(env.contains("DB_DATABASE=app"))
        XCTAssertTrue(env.contains("DB_USERNAME=dev"))
        XCTAssertTrue(env.contains("DB_SSLMODE=require"), "non-prefer sslmode is emitted")
    }

    func testLaravelEnvOmitsSslmodeWhenPrefer() {
        let c = Connection(name: "X", host: "h", database: "d", username: "u", sslMode: .prefer)
        XCTAssertFalse(ConnectionExchange.render(c, format: .laravelEnv).contains("DB_SSLMODE"))
    }

    func testLaravelEnvQuotesAndEscapesSpecialValues() {
        // A database name with spaces/quote/backslash exercises envEscape's
        // needs-quotes + escape path.
        let c = Connection(name: "X", host: "h", database: "my \"weird\\db", username: "u")
        let env = ConnectionExchange.render(c, format: .laravelEnv)
        XCTAssertTrue(env.contains("DB_DATABASE=\"my \\\"weird\\\\db\""), env)
    }

    func testLaravelVaultIsValidJSONWithKeys() throws {
        let c = Connection(name: "X", host: "h", port: 5432, database: "d",
                           username: "u", sslMode: .verifyFull)
        let json = ConnectionExchange.render(c, format: .laravelVault)
        let obj = try XCTUnwrap(
            JSONSerialization.jsonObject(with: Data(json.utf8)) as? [String: Any])
        XCTAssertEqual(obj["DB_CONNECTION"] as? String, "pgsql")
        XCTAssertEqual(obj["DB_HOST"] as? String, "h")
        XCTAssertEqual(obj["DB_SSLMODE"] as? String, "verify-full")
    }

    func testConnectionURLFullForm() {
        let c = Connection(name: "X", host: "db.example.com", port: 6543,
                           database: "app", username: "u@org", sslMode: .verifyCA)
        let url = ConnectionExchange.render(c, format: .connectionURL)
        XCTAssertTrue(url.hasPrefix("postgres://"))
        XCTAssertTrue(url.contains("u%40org@"), "username is percent-encoded")
        XCTAssertTrue(url.contains("db.example.com:6543/app"))
        XCTAssertTrue(url.contains("?sslmode=verify-ca"))
    }

    func testConnectionURLMinimalForm() {
        // Empty username, default port, empty database, prefer sslmode → the
        // short branches: no user@, no :port, no db path, no query.
        let c = Connection(name: "X", host: "localhost", port: 5432,
                           database: "", username: "", sslMode: .prefer)
        XCTAssertEqual(ConnectionExchange.render(c, format: .connectionURL),
                       "postgres://localhost/")
    }

    func testPGBrainRenderOmitsPasswordByDefault() {
        let c = Connection(name: "X", host: "h", database: "d", username: "u")
        let json = ConnectionExchange.render(c, format: .pgbrain)
        XCTAssertTrue(json.contains("\"pgbrain.connection\""))
        XCTAssertFalse(json.contains("\"password\""), "no password without opt-in")
    }
}
