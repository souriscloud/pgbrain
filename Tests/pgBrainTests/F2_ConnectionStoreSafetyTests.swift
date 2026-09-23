import Foundation
import Security
import XCTest
@testable import pgBrain

/// connections.json that exists but can't be read, or that needs a backup
/// that fails, must never be overwritten by the next save. Keychain checks
/// run through the injectable closures only — never the real keychain.
@MainActor
final class F2_ConnectionStoreSafetyTests: XCTestCase {
    private let dir = FileManager.default.temporaryDirectory.appendingPathComponent("pgbrain-f2store-\(UUID().uuidString)")

    override func setUpWithError() throws {
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: dir.path)
        try? FileManager.default.removeItem(at: dir)
    }

    func testMissingFileAllowsSaving() {
        let url = dir.appendingPathComponent("connections.json")
        let store = ConnectionStore(testURL: url)
        XCTAssertFalse(store.saveBlocked)
        store.upsert(Connection(name: "one"))
        XCTAssertEqual(ConnectionStore(testURL: url).connections.map(\.name), ["one"])
    }

    func testUnreadableFileBlocksSaving() throws {
        let url = dir.appendingPathComponent("connections.json")
        let original = Data(#"[{"name":"precious"}]"#.utf8)
        try original.write(to: url)
        try FileManager.default.setAttributes([.posixPermissions: 0o000], ofItemAtPath: url.path)
        defer { try? FileManager.default.setAttributes([.posixPermissions: 0o644], ofItemAtPath: url.path) }

        let store = ConnectionStore(testURL: url)
        XCTAssertTrue(store.connections.isEmpty)
        XCTAssertTrue(store.saveBlocked)
        XCTAssertNotNil(store.saveBlockedReason)
        store.upsert(Connection(name: "new"))

        try FileManager.default.setAttributes([.posixPermissions: 0o644], ofItemAtPath: url.path)
        XCTAssertEqual(try Data(contentsOf: url), original, "the unreadable file was left alone")
    }

    func testFailedBackupBlocksSavingUntilABackupSucceeds() throws {
        let url = dir.appendingPathComponent("connections.json")
        let damaged = Data("{not json".utf8)
        try damaged.write(to: url)
        try FileManager.default.setAttributes([.posixPermissions: 0o555], ofItemAtPath: dir.path)

        let store = ConnectionStore(testURL: url)
        XCTAssertTrue(store.saveBlocked)
        store.upsert(Connection(name: "fresh"))
        XCTAssertEqual(try Data(contentsOf: url), damaged)

        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: dir.path)
        store.save()
        XCTAssertFalse(store.saveBlocked)
        let backups = try FileManager.default.contentsOfDirectory(atPath: dir.path).filter { $0.contains(".bak-") }
        XCTAssertEqual(backups.count, 1)
        XCTAssertEqual(try Data(contentsOf: dir.appendingPathComponent(backups[0])), damaged)
        XCTAssertEqual(ConnectionStore(testURL: url).connections.map(\.name), ["fresh"])
    }

    func testIsFileMissing() {
        XCTAssertTrue(ConnectionStore.isFileMissing(NSError(domain: NSCocoaErrorDomain, code: NSFileReadNoSuchFileError)))
        XCTAssertFalse(ConnectionStore.isFileMissing(NSError(domain: NSCocoaErrorDomain, code: NSFileReadNoPermissionError)))
        XCTAssertTrue(ConnectionStore.isFileMissing(NSError(domain: NSPOSIXErrorDomain, code: Int(ENOENT))))
    }

    // MARK: Keychain status

    func testKeychainClassify() {
        XCTAssertEqual(Keychain.classify(status: errSecSuccess, data: Data("x".utf8), legacy: { .notFound }), .found)
        XCTAssertEqual(Keychain.classify(status: errSecItemNotFound, data: nil, legacy: { .notFound }), .notFound)
        XCTAssertEqual(Keychain.classify(status: errSecItemNotFound, data: nil, legacy: { .found }), .found)
        XCTAssertEqual(Keychain.classify(status: errSecInteractionNotAllowed, data: nil, legacy: { .notFound }),
                       .error(errSecInteractionNotAllowed))
        XCTAssertEqual(Keychain.classify(status: errSecAuthFailed, data: nil, legacy: { .notFound }),
                       .error(errSecAuthFailed))
    }

    func testFillPasswordsOnlyWhenKeychainSaysNotFound() {
        let url = dir.appendingPathComponent("connections.json")
        let store = ConnectionStore(testURL: url)
        let found = Connection(name: "found", host: "h", port: 5432, database: "d", username: "u")
        let locked = Connection(name: "locked", host: "h", port: 5432, database: "d", username: "u")
        let missing = Connection(name: "missing", host: "h", port: 5432, database: "d", username: "u")
        [found, locked, missing].forEach(store.upsert)
        let statuses: [UUID: Keychain.PasswordStatus] = [
            found.id: .found, locked.id: .error(errSecInteractionNotAllowed), missing.id: .notFound,
        ]
        var stored: [UUID: String] = [:]
        let n = store.fillPasswords(
            from: ConnInfoParser.parsePgPass("h:5432:d:u:pw"),
            passwordStatus: { statuses[$0] ?? .notFound },
            store: { stored[$1] = $0 })
        XCTAssertEqual(n, 1)
        XCTAssertEqual(stored, [missing.id: "pw"])
    }
}
