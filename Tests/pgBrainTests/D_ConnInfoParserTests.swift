import XCTest
@testable import pgBrain

final class D_ConnInfoParserTests: XCTestCase {

    // MARK: URI

    func testFullURI() throws {
        let p = try ConnInfoParser.parse(
            "postgresql://al%40ice:p%3Ass%2Fw@db.example.com:6543/my%20db?sslmode=verify-full&application_name=x&sslrootcert=~/ca.pem&connect_timeout=5")
        XCTAssertEqual(p.user, "al@ice")
        XCTAssertEqual(p.password, "p:ss/w")
        XCTAssertEqual(p.host, "db.example.com")
        XCTAssertEqual(p.port, 6543)
        XCTAssertEqual(p.database, "my db")
        XCTAssertEqual(p.sslMode, .verifyFull)
        XCTAssertEqual(p.applicationName, "x")
        XCTAssertEqual(p.sslRootCert, "~/ca.pem")
        XCTAssertEqual(p.ignored["connect_timeout"], "5")
    }

    func testMinimalURIAndSchemeCase() throws {
        let p = try ConnInfoParser.parse("  POSTGRES://localhost  ")
        XCTAssertEqual(p.host, "localhost")
        XCTAssertNil(p.port)
        XCTAssertNil(p.user)
        XCTAssertNil(p.database)
    }

    func testIPv6AndMultiHostURI() throws {
        let v6 = try ConnInfoParser.parse("postgres://u@[::1]:5433/db")
        XCTAssertEqual(v6.host, "::1")
        XCTAssertEqual(v6.port, 5433)
        let multi = try ConnInfoParser.parse("postgres://u@h1:5432,h2:5433/db")
        XCTAssertEqual(multi.host, "h1")
        XCTAssertEqual(multi.port, 5432)
    }

    func testURIOptionsParameterMapsSessionSettings() throws {
        let p = try ConnInfoParser.parse(
            "postgres://h/db?options=-c%20statement_timeout%3D5000%20-c%20default_transaction_read_only%3Don%20--idle_in_transaction_session_timeout%3D2min")
        XCTAssertEqual(p.statementTimeoutSeconds, 5)
        XCTAssertEqual(p.readOnly, true)
        XCTAssertEqual(p.idleInTransactionTimeoutSeconds, 120)
    }

    func testURIErrors() {
        XCTAssertThrowsError(try ConnInfoParser.parse("postgres://h:notaport/db"))
        XCTAssertThrowsError(try ConnInfoParser.parse("postgres://h/db?sslmode=bogus"))
        XCTAssertThrowsError(try ConnInfoParser.parse("postgres://[::1/db"))
        XCTAssertEqual((try? ConnInfoParser.parse("   ")) == nil, true)
        XCTAssertThrowsError(try ConnInfoParser.parse("just some words")) { error in
            XCTAssertEqual(error as? ConnInfoParser.ParseError, .unrecognised)
        }
    }

    // MARK: key=value

    func testKeyValueWithQuotingAndEscapes() throws {
        let p = try ConnInfoParser.parse(#"host=db.local port = 5433 dbname='my db' user=bob password='it\'s a \\secret' sslmode=require"#)
        XCTAssertEqual(p.host, "db.local")
        XCTAssertEqual(p.port, 5433)
        XCTAssertEqual(p.database, "my db")
        XCTAssertEqual(p.user, "bob")
        XCTAssertEqual(p.password, #"it's a \secret"#)
        XCTAssertEqual(p.sslMode, .require)
    }

    func testKeyValueErrors() {
        XCTAssertThrowsError(try ConnInfoParser.parseKeyValue("host"))
        XCTAssertThrowsError(try ConnInfoParser.parseKeyValue("host='unterminated"))
        XCTAssertThrowsError(try ConnInfoParser.parseKeyValue("=value"))
    }

    func testHostaddrOnlyUsedWithoutHost() throws {
        XCTAssertEqual(try ConnInfoParser.parse("hostaddr=10.0.0.1 dbname=x").host, "10.0.0.1")
        XCTAssertEqual(try ConnInfoParser.parse("host=name hostaddr=10.0.0.1").host, "name")
    }

    func testDurationSeconds() {
        XCTAssertEqual(ConnInfoParser.durationSeconds("1500"), 2)
        XCTAssertEqual(ConnInfoParser.durationSeconds("30s"), 30)
        XCTAssertEqual(ConnInfoParser.durationSeconds("2min"), 120)
        XCTAssertEqual(ConnInfoParser.durationSeconds("1h"), 3600)
        XCTAssertEqual(ConnInfoParser.durationSeconds("0"), 0)
        XCTAssertNil(ConnInfoParser.durationSeconds("soon"))
        XCTAssertNil(ConnInfoParser.durationSeconds("5 fortnights"))
    }

    // MARK: apply

    func testApplyOnlyTouchesSpecifiedFields() throws {
        var c = Connection(name: "keep", host: "old", port: 1111, database: "olddb", username: "olduser",
                           sslMode: .disable, colorTag: .red, isProduction: true)
        let pw = ConnInfoParser.apply(try ConnInfoParser.parse("host=/tmp dbname=new sslmode=verify-ca sslcert=c.pem sslkey=k.pem password=pw"), to: &c)
        XCTAssertEqual(pw, "pw")
        XCTAssertEqual(c.host, "localhost", "unix-socket dirs map to localhost")
        XCTAssertEqual(c.port, 1111)
        XCTAssertEqual(c.database, "new")
        XCTAssertEqual(c.username, "olduser")
        XCTAssertEqual(c.sslMode, .verifyCA)
        XCTAssertEqual(c.sslClientCertPath, "c.pem")
        XCTAssertEqual(c.sslClientKeyPath, "k.pem")
        XCTAssertEqual(c.name, "keep")
        XCTAssertEqual(c.colorTag, .red)
        XCTAssertTrue(c.isProduction)
    }

    // MARK: .pgpass

    func testPgPassParseAndLookup() {
        let text = """
        # comment
        db.example.com:5432:app:alice:s3cr\\:et
        *:*:*:bob:bobpw
        localhost:5432:*:*:local\\\\pw
        broken:line
        """
        let entries = ConnInfoParser.parsePgPass(text)
        XCTAssertEqual(entries.count, 3)
        XCTAssertEqual(entries[0].password, "s3cr:et")
        XCTAssertEqual(entries[2].password, #"local\pw"#)
        XCTAssertEqual(ConnInfoParser.pgpassLookup(entries, host: "db.example.com", port: 5432, database: "app", user: "alice"), "s3cr:et")
        XCTAssertNil(ConnInfoParser.pgpassLookup(entries, host: "db.example.com", port: 5433, database: "app", user: "alice"))
        XCTAssertEqual(ConnInfoParser.pgpassLookup(entries, host: "anything", port: 1, database: "x", user: "bob"), "bobpw")
        XCTAssertEqual(ConnInfoParser.pgpassLookup(entries, host: "localhost", port: 5432, database: "z", user: "carol"), #"local\pw"#)
    }

    func testPgPassPasswordWithUnescapedColonKeepsRemainder() {
        let entries = ConnInfoParser.parsePgPass("h:1:d:u:a:b:c")
        XCTAssertEqual(entries.first?.password, "a:b:c")
    }

    // MARK: pg_service.conf

    func testServiceFile() {
        let text = """
        # services
        [prod]
        host=prod.example.com
        port=6432
        dbname=app
        user=deploy
        sslmode=verify-full

        [local]
        host = localhost
        dbname = dev
        stray line without equals
        """
        let services = ConnInfoParser.parseServiceFile(text)
        XCTAssertEqual(services.map(\.name), ["prod", "local"])
        let (prod, pw) = ConnInfoParser.connection(from: services[0])
        XCTAssertNil(pw)
        XCTAssertEqual(prod.name, "prod")
        XCTAssertEqual(prod.host, "prod.example.com")
        XCTAssertEqual(prod.port, 6432)
        XCTAssertEqual(prod.username, "deploy")
        XCTAssertEqual(prod.sslMode, .verifyFull)
        let (local, _) = ConnInfoParser.connection(from: services[1])
        XCTAssertEqual(local.host, "localhost")
        XCTAssertEqual(local.port, 5432)
        XCTAssertEqual(local.database, "dev")
    }

    @MainActor
    func testFillPasswordsOnlyForConnectionsWithoutOne() {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("pgbrain-d-\(UUID().uuidString).json")
        defer { try? FileManager.default.removeItem(at: url) }
        let store = ConnectionStore(testURL: url)
        let has = Connection(name: "has", host: "h", port: 5432, database: "d", username: "u")
        let missing = Connection(name: "missing", host: "h", port: 5432, database: "d", username: "u")
        let nomatch = Connection(name: "nomatch", host: "other", port: 5432, database: "d", username: "u")
        [has, missing, nomatch].forEach(store.upsert)
        var stored: [UUID: String] = [:]
        let n = store.fillPasswords(
            from: ConnInfoParser.parsePgPass("h:5432:d:u:pw"),
            hasPassword: { $0 == has.id },
            store: { stored[$1] = $0 })
        XCTAssertEqual(n, 1)
        XCTAssertEqual(stored, [missing.id: "pw"])
    }
}
