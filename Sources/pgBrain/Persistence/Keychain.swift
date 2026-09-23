import Foundation
import Security

/// Stores connection passwords as Keychain generic-password items keyed
/// by connection UUID.
///
/// Items live in the login (file-based) keychain with the **default ACL**:
/// only pgBrain itself reads silently, any other app triggers a prompt. For
/// the Developer ID build the ACL is bound to the designated requirement
/// (team + bundle id), so Sparkle updates keep silent access. Ad-hoc dev
/// builds get a fresh signature per build and see a one-time prompt.
///
/// Why not the data-protection keychain (`kSecUseDataProtectionKeychain`):
/// on macOS it requires a `keychain-access-groups` / application-identifier
/// entitlement, which for a Developer ID app means an embedded provisioning
/// profile. The release build ships with no entitlements and no profile, so
/// the call would fail with `errSecMissingEntitlement`.
///
/// Migration: builds ≤ 0.9.x wrote items under `legacyService` with a custom
/// "every application is trusted" ACL. On first read an item is copied to
/// `service` (default ACL), verified by reading it back, and only then is
/// the legacy item deleted.
enum Keychain {
    static let service = "cloud.souris.pgbrain.connection"
    static let legacyService = "cloud.souris.pgbrain"

    enum KeychainError: Error, CustomStringConvertible {
        case unhandled(OSStatus)
        case verificationFailed
        var description: String {
            switch self {
            case .unhandled(let status):
                let msg = SecCopyErrorMessageString(status, nil) as String? ?? "OSStatus \(status)"
                return "Keychain error: \(msg)"
            case .verificationFailed:
                return "Keychain error: the stored password could not be read back."
            }
        }
    }

    private static func baseQuery(service: String, account: String) -> [CFString: Any] {
        [
            kSecClass: kSecClassGenericPassword,
            kSecAttrService: service,
            kSecAttrAccount: account,
        ]
    }

    /// Update in place, add only when missing. Never deletes first: a failed
    /// add after a delete would lose the password.
    static func setPassword(_ password: String, for connectionID: UUID) throws {
        let account = connectionID.uuidString
        try write(Data(password.utf8), service: service, account: account)
        // The new item is in place; a stale legacy copy would otherwise be
        // re-migrated over it on a later read.
        _ = SecItemDelete(baseQuery(service: legacyService, account: account) as CFDictionary)
    }

    private static func write(_ data: Data, service: String, account: String) throws {
        let query = baseQuery(service: service, account: account)
        let update: [CFString: Any] = [kSecValueData: data]
        let status = SecItemUpdate(query as CFDictionary, update as CFDictionary)
        switch status {
        case errSecSuccess:
            return
        case errSecItemNotFound:
            var add = query
            add[kSecValueData] = data
            add[kSecAttrLabel] = "pgBrain connection password"
            let addStatus = SecItemAdd(add as CFDictionary, nil)
            guard addStatus == errSecSuccess else { throw KeychainError.unhandled(addStatus) }
        default:
            throw KeychainError.unhandled(status)
        }
    }

    private static func read(service: String, account: String) -> (OSStatus, Data?) {
        var query = baseQuery(service: service, account: account)
        query[kSecReturnData] = true
        query[kSecMatchLimit] = kSecMatchLimitOne
        var result: AnyObject?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        return (status, result as? Data)
    }

    /// Synchronous and potentially slow (a keychain prompt can block for as
    /// long as the user takes to answer) — call from a background task.
    static func password(for connectionID: UUID) -> String? {
        let account = connectionID.uuidString
        let (status, data) = read(service: service, account: account)
        if status == errSecSuccess, let data {
            return String(data: data, encoding: .utf8)
        }
        guard status == errSecItemNotFound else { return nil }
        return migrateLegacy(account: account)
    }

    /// Off-main convenience for UI code.
    static func passwordAsync(for connectionID: UUID) async -> String? {
        await Task.detached(priority: .userInitiated) { password(for: connectionID) }.value
    }

    private static func migrateLegacy(account: String) -> String? {
        let (status, data) = read(service: legacyService, account: account)
        guard status == errSecSuccess, let data, let password = String(data: data, encoding: .utf8) else {
            return nil
        }
        do {
            try write(data, service: service, account: account)
            let (verifyStatus, verifyData) = read(service: service, account: account)
            guard verifyStatus == errSecSuccess, verifyData == data else {
                throw KeychainError.verificationFailed
            }
            _ = SecItemDelete(baseQuery(service: legacyService, account: account) as CFDictionary)
        } catch {
            Log.persistence.error("keychain migration kept legacy item: \(String(describing: error), privacy: .public)")
        }
        return password
    }

    static func deletePassword(for connectionID: UUID) {
        let account = connectionID.uuidString
        _ = SecItemDelete(baseQuery(service: service, account: account) as CFDictionary)
        _ = SecItemDelete(baseQuery(service: legacyService, account: account) as CFDictionary)
    }
}
