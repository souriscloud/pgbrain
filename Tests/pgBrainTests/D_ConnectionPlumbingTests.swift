import AppKit
import NIOSSL
import PostgresNIO
import Security
import XCTest
@testable import pgBrain

@MainActor
private final class TestFlag {
    var on = true
}

private func tempFile(_ ext: String = "json") -> URL {
    FileManager.default.temporaryDirectory.appendingPathComponent("pgbrain-d-\(UUID().uuidString).\(ext)")
}

// MARK: - Connection model resilience

final class D_ConnectionModelTests: XCTestCase {
    func testUnknownEnumRawValuesFallBackInsteadOfFailing() throws {
        let json = #"{"id":"6F9619FF-8B86-D011-B42D-00C04FC964FF","name":"n","sslMode":"verify-quantum","colorTag":"ultraviolet","port":"not-a-number"}"#
        let c = try JSONDecoder().decode(Connection.self, from: Data(json.utf8))
        XCTAssertEqual(c.name, "n")
        XCTAssertEqual(c.sslMode, .prefer)
        XCTAssertEqual(c.colorTag, .none)
        XCTAssertEqual(c.port, 5432)
        XCTAssertFalse(c.readOnly)
        XCTAssertEqual(c.statementTimeoutSeconds, 0)
    }

    func testNewFieldsRoundTrip() throws {
        let c = Connection(name: "x", sslRootCertPath: "~/ca.pem", sslClientCertPath: "c", sslClientKeyPath: "k",
                           statementTimeoutSeconds: 30, idleInTransactionTimeoutSeconds: 60, readOnly: true)
        let back = try JSONDecoder().decode(Connection.self, from: JSONEncoder().encode(c))
        XCTAssertEqual(back, c)
    }

    func testStartupParameters() {
        var c = Connection(name: "x")
        XCTAssertEqual(c.startupParameters().map(\.0), ["application_name"])
        XCTAssertEqual(c.startupParameters().first?.1, "pgBrain")
        c.statementTimeoutSeconds = 30
        c.idleInTransactionTimeoutSeconds = 120
        c.readOnly = true
        let params = Dictionary(uniqueKeysWithValues: c.startupParameters(applicationName: "pgBrain · w").map { ($0.0, $0.1) })
        XCTAssertEqual(params["application_name"], "pgBrain · w")
        XCTAssertEqual(params["statement_timeout"], "30s")
        XCTAssertEqual(params["idle_in_transaction_session_timeout"], "120s")
        XCTAssertEqual(params["default_transaction_read_only"], "on")
    }
}

// MARK: - ConnectionStore resilience

@MainActor
final class D_ConnectionStoreResilienceTests: XCTestCase {
    private func backups(for url: URL) -> [URL] {
        let dir = url.deletingLastPathComponent()
        return ((try? FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil)) ?? [])
            .filter { $0.lastPathComponent.hasPrefix(url.lastPathComponent + ".bak-") }
    }

    func testBadElementIsDroppedNotTheWholeListAndFileIsBackedUp() throws {
        let url = tempFile()
        defer {
            try? FileManager.default.removeItem(at: url)
            backups(for: url).forEach { try? FileManager.default.removeItem(at: $0) }
        }
        let json = """
        [
          {"id":"6F9619FF-8B86-D011-B42D-00C04FC964FF","name":"good","sslMode":"verify-quantum"},
          "garbage",
          42,
          {"name":"also good","colorTag":"infrared"}
        ]
        """
        try Data(json.utf8).write(to: url)
        let store = ConnectionStore(testURL: url)
        XCTAssertEqual(store.connections.map(\.name), ["good", "also good"])
        let baks = backups(for: url)
        XCTAssertEqual(baks.count, 1)
        XCTAssertEqual(try Data(contentsOf: baks[0]), Data(json.utf8), "backup is byte-identical")

        store.upsert(Connection(name: "new"))
        XCTAssertEqual(try Data(contentsOf: baks[0]), Data(json.utf8), "save never touches the backup")
    }

    func testUnreadableFileIsBackedUpBeforeOverwrite() throws {
        let url = tempFile()
        defer {
            try? FileManager.default.removeItem(at: url)
            backups(for: url).forEach { try? FileManager.default.removeItem(at: $0) }
        }
        try Data("{not json".utf8).write(to: url)
        let store = ConnectionStore(testURL: url)
        XCTAssertTrue(store.connections.isEmpty)
        XCTAssertEqual(backups(for: url).count, 1)
        store.upsert(Connection(name: "fresh"))
        XCTAssertEqual(ConnectionStore(testURL: url).connections.map(\.name), ["fresh"])
    }

    func testCleanFileMakesNoBackup() throws {
        let url = tempFile()
        defer { try? FileManager.default.removeItem(at: url) }
        let a = ConnectionStore(testURL: url)
        a.upsert(Connection(name: "one"))
        _ = ConnectionStore(testURL: url)
        XCTAssertTrue(backups(for: url).isEmpty)
    }
}

// MARK: - Keychain

final class D_KeychainTests: XCTestCase {
    private func legacyAdd(_ password: String, id: UUID) -> OSStatus {
        let q: [CFString: Any] = [
            kSecClass: kSecClassGenericPassword,
            kSecAttrService: Keychain.legacyService,
            kSecAttrAccount: id.uuidString,
            kSecValueData: Data(password.utf8),
        ]
        return SecItemAdd(q as CFDictionary, nil)
    }

    private func legacyExists(_ id: UUID) -> Bool {
        let q: [CFString: Any] = [
            kSecClass: kSecClassGenericPassword,
            kSecAttrService: Keychain.legacyService,
            kSecAttrAccount: id.uuidString,
        ]
        return SecItemCopyMatching(q as CFDictionary, nil) == errSecSuccess
    }

    func testSetUpdatesInPlaceAndDeletes() throws {
        let id = UUID()
        defer { Keychain.deletePassword(for: id) }
        do {
            try Keychain.setPassword("first", for: id)
        } catch {
            throw XCTSkip("Keychain unavailable in this environment: \(error)")
        }
        XCTAssertEqual(Keychain.password(for: id), "first")
        try Keychain.setPassword("second", for: id)
        XCTAssertEqual(Keychain.password(for: id), "second")
        Keychain.deletePassword(for: id)
        XCTAssertNil(Keychain.password(for: id))
    }

    func testLegacyItemMigratesThenLegacyIsDeleted() throws {
        let id = UUID()
        defer { Keychain.deletePassword(for: id) }
        guard legacyAdd("old-secret", id: id) == errSecSuccess else {
            throw XCTSkip("Keychain unavailable in this environment")
        }
        XCTAssertEqual(Keychain.password(for: id), "old-secret")
        XCTAssertFalse(legacyExists(id), "legacy copy removed after verified migration")
        XCTAssertEqual(Keychain.password(for: id), "old-secret", "served from the new item")
    }

    func testSetPasswordRemovesStaleLegacyCopy() throws {
        let id = UUID()
        defer { Keychain.deletePassword(for: id) }
        guard legacyAdd("stale", id: id) == errSecSuccess else {
            throw XCTSkip("Keychain unavailable in this environment")
        }
        try Keychain.setPassword("fresh", for: id)
        XCTAssertFalse(legacyExists(id))
        XCTAssertEqual(Keychain.password(for: id), "fresh")
    }
}

// MARK: - SSH

final class D_SSHCommandTests: XCTestCase {
    private func conn() -> Connection {
        Connection(name: "c", host: "db.internal", port: 5433, username: "app",
                   sshEnabled: true, sshHost: "bastion.example.com", sshPort: 2222, sshUser: "ec2-user")
    }

    func testArgumentsCarryHardeningOptionsAndDoubleDash() throws {
        let args = try SSHCommand.arguments(for: conn(), localPort: 40000)
        for opt in ["BatchMode=yes", "ConnectTimeout=10", "StrictHostKeyChecking=accept-new",
                    "ExitOnForwardFailure=yes", "ServerAliveInterval=30"] {
            XCTAssertTrue(args.contains(opt), "missing \(opt)")
        }
        XCTAssertEqual(args[args.firstIndex(of: "-L")! + 1], "127.0.0.1:40000:db.internal:5433")
        XCTAssertEqual(args[args.firstIndex(of: "-p")! + 1], "2222")
        XCTAssertEqual(args.suffix(2), ["--", "ec2-user@bastion.example.com"])
        XCTAssertFalse(args.contains("-i"))
    }

    func testKeyPathIsExpandedAndIdentitiesOnly() throws {
        var c = conn()
        c.sshKeyPath = "~/.ssh/id_test"
        let args = try SSHCommand.arguments(for: c, localPort: 1)
        let key = args[args.firstIndex(of: "-i")! + 1]
        XCTAssertFalse(key.hasPrefix("~"))
        XCTAssertTrue(key.hasSuffix("/.ssh/id_test"))
        XCTAssertTrue(args.contains("IdentitiesOnly=yes"))
    }

    func testIPv6DatabaseHostIsBracketedAndEmptyUserOmitted() throws {
        var c = conn()
        c.host = "fd00::5"
        c.sshUser = ""
        let args = try SSHCommand.arguments(for: c, localPort: 1)
        XCTAssertEqual(args[args.firstIndex(of: "-L")! + 1], "127.0.0.1:1:[fd00::5]:5433")
        XCTAssertEqual(args.last, "bastion.example.com")
    }

    func testValidationRejectsOptionInjection() {
        for (host, user) in [("-oProxyCommand=evil", "u"), ("bastion", "-oProxyCommand=evil"),
                             ("bas tion", "u"), ("bastion", "u\nx"), ("", "u"), ("u@bastion", "x")] {
            var c = conn()
            c.sshHost = host
            c.sshUser = user
            XCTAssertThrowsError(try SSHCommand.arguments(for: c, localPort: 1), "\(host) / \(user)")
        }
        var badPort = conn()
        badPort.sshPort = 0
        XCTAssertThrowsError(try SSHCommand.validate(badPort))
        var atUser = conn()
        atUser.sshUser = "alice@corp.example"
        XCTAssertNoThrow(try SSHCommand.validate(atUser))
    }

    func testFriendlyErrors() {
        let c = conn()
        let auth = SSHCommand.friendlyError(stderr: "ec2-user@bastion: Permission denied (publickey).", exitCode: 255, connection: c)
        XCTAssertTrue(auth.contains("ssh-agent"))
        let hostKey = SSHCommand.friendlyError(stderr: "@@@ WARNING: REMOTE HOST IDENTIFICATION HAS CHANGED! @@@\nHost key verification failed.", exitCode: 255, connection: c)
        XCTAssertTrue(hostKey.contains("ssh-keygen -R bastion.example.com"))
        XCTAssertEqual(SSHCommand.friendlyError(stderr: "  ", exitCode: 255, connection: c), "ssh exited with status 255.")
    }

    @MainActor
    func testImportedSSHFieldsAreSanitized() throws {
        let raw = """
        {"pgbrain.connection":"v1","name":"evil","host":"db","sshEnabled":true,"sshHost":"-oProxyCommand=touch /tmp/pwn","sshUser":"u","sshPort":99999}
        """
        let imported = try XCTUnwrap(ConnectionExchange.parse(raw))
        XCTAssertFalse(imported.connection.sshEnabled)
        XCTAssertEqual(imported.connection.sshHost, "")
        XCTAssertEqual(imported.connection.sshPort, 22)
        XCTAssertFalse(imported.warnings.isEmpty)
    }

    @MainActor
    func testReleasingLastOwnerForgetsTunnel() {
        let id = UUID()
        SSHTunnelManager.shared.release(connectionID: id, owner: "nobody")
        XCTAssertNil(SSHTunnelManager.shared.localPort(for: id))
    }

    func testCanConnectReportsClosedPort() throws {
        let port = try SSHTunnelManager.findFreePort()
        XCTAssertFalse(SSHTunnelManager.canConnect(port: port))
    }
}

// MARK: - TLS configuration

final class D_TLSConfigurationTests: XCTestCase {
    private var dir: URL!

    override func setUpWithError() throws {
        dir = FileManager.default.temporaryDirectory.appendingPathComponent("pgbrain-tls-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: dir)
    }

    private func makeCertAndKey() throws -> (cert: String, key: String) {
        let cert = dir.appendingPathComponent("client.pem").path
        let key = dir.appendingPathComponent("client.key").path
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/openssl")
        p.arguments = ["req", "-x509", "-newkey", "rsa:2048", "-nodes", "-keyout", key, "-out", cert,
                       "-subj", "/CN=pgbrain-test", "-days", "1"]
        p.standardOutput = FileHandle.nullDevice
        p.standardError = FileHandle.nullDevice
        do { try p.run() } catch { throw XCTSkip("openssl unavailable: \(error)") }
        p.waitUntilExit()
        guard p.terminationStatus == 0 else { throw XCTSkip("openssl failed") }
        return (cert, key)
    }

    private func conn(_ mode: Connection.SSLMode, root: String = "", cert: String = "", key: String = "") -> Connection {
        Connection(name: "t", host: "db.example.com", sslMode: mode,
                   sslRootCertPath: root, sslClientCertPath: cert, sslClientKeyPath: key)
    }

    func testModeToVerification() throws {
        XCTAssertNil(try ConnectionService.tlsConfiguration(for: conn(.disable)))
        XCTAssertEqual(try ConnectionService.tlsConfiguration(for: conn(.prefer))?.certificateVerification, CertificateVerification.none)
        XCTAssertEqual(try ConnectionService.tlsConfiguration(for: conn(.require))?.certificateVerification, CertificateVerification.none)
        XCTAssertEqual(try ConnectionService.tlsConfiguration(for: conn(.verifyCA))?.certificateVerification, .noHostnameVerification)
        XCTAssertEqual(try ConnectionService.tlsConfiguration(for: conn(.verifyFull))?.certificateVerification, .fullVerification)
    }

    func testRootCertSetsTrustRootsAndUpgradesRequire() throws {
        let (cert, _) = try makeCertAndKey()
        let require = try XCTUnwrap(ConnectionService.tlsConfiguration(for: conn(.require, root: cert)))
        XCTAssertEqual(require.certificateVerification, .noHostnameVerification, "require + root CA behaves like verify-ca")
        XCTAssertEqual(require.trustRoots, .file(cert))
        let verifyCA = try XCTUnwrap(ConnectionService.tlsConfiguration(for: conn(.verifyCA, root: cert)))
        XCTAssertEqual(verifyCA.certificateVerification, .noHostnameVerification, "verify-ca never checks the hostname")
        let prefer = try XCTUnwrap(ConnectionService.tlsConfiguration(for: conn(.prefer, root: cert)))
        XCTAssertNotEqual(prefer.trustRoots, .file(cert), "prefer ignores the root CA")
    }

    func testClientCertificateAndKeyLoad() throws {
        let (cert, key) = try makeCertAndKey()
        let tls = try XCTUnwrap(ConnectionService.tlsConfiguration(for: conn(.verifyFull, cert: cert, key: key)))
        XCTAssertEqual(tls.certificateChain.count, 1)
        XCTAssertNotNil(tls.privateKey)
    }

    func testMissingFilesAndKeyAreReported() throws {
        XCTAssertThrowsError(try ConnectionService.tlsConfiguration(for: conn(.verifyCA, root: "/nope/ca.pem"))) { error in
            guard case ConnectionService.TLSSetupError.fileNotFound = error else { return XCTFail("\(error)") }
        }
        let (cert, _) = try makeCertAndKey()
        XCTAssertThrowsError(try ConnectionService.tlsConfiguration(for: conn(.require, cert: cert))) { error in
            XCTAssertEqual(error as? ConnectionService.TLSSetupError, .clientKeyMissing)
        }
    }

    func testServerNameUsesRealHostEvenThroughTunnel() throws {
        var c = conn(.verifyFull)
        c.username = "u"
        c.database = "d"
        c.readOnly = true
        let config = try ConnectionService.clientConfiguration(
            for: c, password: "", endpoint: .init(host: "127.0.0.1", port: 40000))
        XCTAssertEqual(config.host, "127.0.0.1")
        XCTAssertEqual(config.port, 40000)
        XCTAssertEqual(config.options.tlsServerName, "db.example.com")
        XCTAssertTrue(config.options.additionalStartupParameters.contains { $0.0 == "default_transaction_read_only" && $0.1 == "on" })

        let probe = try ConnectionService.connectionConfiguration(
            for: c, password: "", endpoint: .init(host: "127.0.0.1", port: 40000))
        XCTAssertEqual(probe.options.tlsServerName, "db.example.com")

        XCTAssertNil(ConnectionService.tlsServerName(for: conn(.disable)))
        XCTAssertNil(ConnectionService.tlsServerName(for: Connection(name: "ip", host: "10.1.2.3", sslMode: .verifyFull)))
        XCTAssertNil(ConnectionService.tlsServerName(for: Connection(name: "ip6", host: "::1", sslMode: .require)))
    }

    func testReconnectBackoffIsCapped() {
        XCTAssertEqual(ConnectionService.reconnectDelay(afterAttempt: 1), .seconds(1))
        XCTAssertEqual(ConnectionService.reconnectDelay(afterAttempt: 3), .seconds(5))
        XCTAssertEqual(ConnectionService.reconnectDelay(afterAttempt: 50), .seconds(30))
    }

    func testWithDeadlineDoesNotWaitForAStuckOperation() async {
        let started = Date()
        do {
            _ = try await ConnectionService.withDeadline(seconds: 0.2, onTimeout: { CancellationError() }) {
                // Ignores cancellation on purpose.
                while Date().timeIntervalSince(started) < 3 { usleep(10_000) }
                return 1
            }
            XCTFail("expected timeout")
        } catch {
            XCTAssertTrue(error is CancellationError)
        }
        XCTAssertLessThan(Date().timeIntervalSince(started), 1.5)
    }
}

// MARK: - Query history

final class D_QueryHistoryRedactionTests: XCTestCase {
    func testPasswordLiteralsAreMasked() {
        let cases: [(String, String)] = [
            ("ALTER ROLE app PASSWORD 'hunter2'", "ALTER ROLE app PASSWORD '********'"),
            ("create user bob with password 'it''s secret' valid until 'infinity'",
             "create user bob with password '********' valid until 'infinity'"),
            ("ALTER USER x PASSWORD E'esc\\'aped'", "ALTER USER x PASSWORD '********'"),
            ("ALTER ROLE x PASSWORD $pw$dollar$pw$", "ALTER ROLE x PASSWORD '********'"),
            ("CREATE USER MAPPING FOR me SERVER s OPTIONS (user 'a', password 'b')",
             "CREATE USER MAPPING FOR me SERVER s OPTIONS (user 'a', password '********')"),
            ("SELECT dblink_connect('host=h password=topsecret dbname=d')",
             "SELECT dblink_connect('host=h password=******** dbname=d')"),
            ("-- postgres://u:pa55@host/db", "-- postgres://u:********@host/db"),
        ]
        for (input, expected) in cases {
            XCTAssertEqual(QueryHistoryRedactor.redact(input), expected, input)
        }
    }

    func testOrdinarySQLIsUntouched() {
        let sql = "SELECT password_hash FROM users WHERE id = 1"
        XCTAssertEqual(QueryHistoryRedactor.redact(sql), sql)
        XCTAssertEqual(QueryHistoryRedactor.redact("SELECT 1"), "SELECT 1")
    }

    @MainActor
    func testStoreRedactsHonoursToggleAndWritesPrivately() throws {
        let url = tempFile()
        defer { try? FileManager.default.removeItem(at: url) }
        let flag = TestFlag()
        let store = QueryHistoryStore(testURL: url, isEnabled: { flag.on })
        let id = UUID()
        store.record(connectionID: id, sql: "ALTER ROLE a PASSWORD 'x'", startedAt: Date(),
                     elapsedSec: 0, success: true, errorMessage: nil, rowsAffected: nil)
        XCTAssertEqual(store.entries.first?.sql, "ALTER ROLE a PASSWORD '********'")
        flag.on = false
        store.record(connectionID: id, sql: "SELECT 2", startedAt: Date(),
                     elapsedSec: 0, success: true, errorMessage: nil, rowsAffected: nil)
        XCTAssertEqual(store.entries.count, 1)
        store.flushNowForTests()
        let text = try String(contentsOf: url, encoding: .utf8)
        XCTAssertFalse(text.contains("'x'"))
        let perms = try FileManager.default.attributesOfItem(atPath: url.path)[.posixPermissions] as? Int
        XCTAssertEqual(perms, 0o600)
        store.clearAll()
        store.flushNowForTests()
        XCTAssertTrue(QueryHistoryStore(testURL: url).entries.isEmpty)
    }

    @MainActor
    func testLegacyPlaintextHistoryIsScrubbedOnLoad() throws {
        let url = tempFile()
        defer { try? FileManager.default.removeItem(at: url) }
        let legacy = [QueryHistoryEntry(id: UUID(), connectionID: UUID(), sql: "ALTER ROLE a PASSWORD 'old'",
                                        startedAt: Date(), elapsedSec: 0, success: true, errorMessage: nil, rowsAffected: nil)]
        try JSONEncoder().encode(legacy).write(to: url)
        let store = QueryHistoryStore(testURL: url)
        XCTAssertEqual(store.entries.first?.sql, "ALTER ROLE a PASSWORD '********'")
        store.flushNowForTests()
        XCTAssertFalse(try String(contentsOf: url, encoding: .utf8).contains("'old'"))
    }
}

// MARK: - Export / clipboard

@MainActor
final class D_ConnectionIOSecurityTests: XCTestCase {
    func testPrivateWriteIsOwnerOnly() throws {
        let url = tempFile()
        defer { try? FileManager.default.removeItem(at: url) }
        try Data("old".utf8).write(to: url)
        try AppSupport.writePrivate(Data("secret".utf8), to: url)
        XCTAssertEqual(try String(contentsOf: url, encoding: .utf8), "secret")
        let perms = try FileManager.default.attributesOfItem(atPath: url.path)[.posixPermissions] as? Int
        XCTAssertEqual(perms, 0o600)
    }

    func testSecretCopyIsConcealedAndTransient() {
        let pb = NSPasteboard(name: NSPasteboard.Name("pgbrain-test-\(UUID().uuidString)"))
        defer { pb.releaseGlobally() }
        ConnectionIO.copyText("pw", containsSecret: true, pasteboard: pb)
        XCTAssertEqual(pb.string(forType: .string), "pw")
        XCTAssertTrue(pb.types?.contains(ConnectionIO.concealedType) ?? false)
        XCTAssertTrue(pb.types?.contains(ConnectionIO.transientType) ?? false)
        ConnectionIO.copyText("plain", containsSecret: false, pasteboard: pb)
        XCTAssertFalse(pb.types?.contains(ConnectionIO.concealedType) ?? true)
    }

    func testBundleRoundTripsNewFields() throws {
        let c = Connection(name: "x", host: "h", sslMode: .verifyFull, sslRootCertPath: "~/ca.pem",
                           statementTimeoutSeconds: 15, readOnly: true)
        let text = ConnectionExchange.renderBundle([c], includePasswords: false)
        let back = try XCTUnwrap(ConnectionExchange.parseBundle(text)?.first?.connection)
        XCTAssertEqual(back.sslRootCertPath, "~/ca.pem")
        XCTAssertEqual(back.statementTimeoutSeconds, 15)
        XCTAssertTrue(back.readOnly)
    }
}
