import Foundation
import Security

/// Stores connection passwords as Keychain generic-password items keyed
/// by connection UUID.
///
/// **Why the rewrite?** The original implementation set
/// `kSecAttrAccessibleAfterFirstUnlock` on its own. That keeps the
/// item *available* without re-auth across reboots, but it doesn't
/// touch the per-item ACL — by default the ACL is "the exact binary
/// that created this item only". On every Sparkle update the
/// designated requirement of our binary is still the same Team ID,
/// but the *binary signature* is different, so macOS treated the new
/// binary as untrusted and threw up the "Always Allow / Allow / Deny"
/// dialog on every password read.
///
/// Fix: create items with a `SecAccessControl` built via
/// `SecAccessControlCreateWithFlags` and an empty flags set. That
/// replaces the implicit "only this specific binary" ACL with one
/// that says "any process can read once the device is unlocked".
/// Code signing + the hardened runtime entitlements still keep
/// third-party apps out — they can't read your Keychain unless they
/// know the right service/account and pass macOS's process-trust
/// checks at the kSec layer. For us it just means the prompt never
/// re-fires after the first install.
///
/// Existing items written by the old scheme get migrated on their
/// next `setPassword` call (we delete-then-add so the ACL is rebuilt).
enum Keychain {
    static let service = "cloud.souris.pgbrain"

    enum KeychainError: Error, CustomStringConvertible {
        case unhandled(OSStatus)
        var description: String {
            switch self {
            case .unhandled(let status):
                let msg = SecCopyErrorMessageString(status, nil) as String? ?? "OSStatus \(status)"
                return "Keychain error: \(msg)"
            }
        }
    }

    /// Legacy-keychain `SecAccess` whose ACL trusts **every** application, so
    /// reads never throw the `Always Allow / Allow / Deny` dialog — no matter
    /// how often the binary's signature changes (dev rebuilds, Sparkle
    /// updates). The previous implementation used `kSecAttrAccessControl`,
    /// which is a *data-protection* keychain attribute and is ignored by the
    /// legacy file keychain we actually write to — so items kept the default
    /// "only this exact binary" ACL and re-prompted on every new build.
    ///
    /// Trade-off: any process running as you can read these DB passwords once
    /// the keychain is unlocked. That's the project's deliberate choice (see
    /// the rewrite note above) for a developer tool that updates frequently.
    private static func makeAllAppsAccess() -> SecAccess? {
        var access: SecAccess?
        guard SecAccessCreate("pgBrain connection password" as CFString, nil, &access) == errSecSuccess,
              let access else { return nil }
        var aclList: CFArray?
        guard SecAccessCopyACLList(access, &aclList) == errSecSuccess,
              let acls = aclList as? [SecACL] else { return access }
        for acl in acls {
            // A nil application list means "any application is trusted" — no
            // prompt. An *empty* array would mean the opposite (always prompt).
            SecACLSetContents(acl, nil, "pgBrain" as CFString, [])
        }
        return access
    }

    /// Connection IDs already re-written with the all-apps ACL. Persisted so
    /// the one-time migration (a delete-then-add) runs exactly once ever, not
    /// on every launch. UserDefaults is thread-safe.
    private static let migratedKey = "cloud.souris.pgbrain.keychainMigratedV1"
    private static func isMigrated(_ id: UUID) -> Bool {
        (UserDefaults.standard.stringArray(forKey: migratedKey) ?? []).contains(id.uuidString)
    }
    private static func markMigrated(_ id: UUID) {
        var ids = UserDefaults.standard.stringArray(forKey: migratedKey) ?? []
        guard !ids.contains(id.uuidString) else { return }
        ids.append(id.uuidString)
        UserDefaults.standard.set(ids, forKey: migratedKey)
    }

    static func setPassword(_ password: String, for connectionID: UUID) throws {
        let account = connectionID.uuidString
        let data = Data(password.utf8)

        // Always delete-then-add so old items get migrated to the new
        // SecAccessControl. Updating an existing item leaves the old
        // ACL in place even if we change kSecAttrAccessible, so
        // post-Sparkle-update reads would still prompt.
        let baseQuery: [CFString: Any] = [
            kSecClass: kSecClassGenericPassword,
            kSecAttrService: service,
            kSecAttrAccount: account
        ]
        _ = SecItemDelete(baseQuery as CFDictionary)

        var addQuery = baseQuery
        addQuery[kSecValueData] = data
        if let access = makeAllAppsAccess() {
            addQuery[kSecAttrAccess] = access
        } else {
            addQuery[kSecAttrAccessible] = kSecAttrAccessibleAfterFirstUnlock
        }
        let addStatus = SecItemAdd(addQuery as CFDictionary, nil)
        if addStatus == errSecSuccess {
            markMigrated(connectionID)
            return
        }
        throw KeychainError.unhandled(addStatus)
    }

    static func password(for connectionID: UUID) -> String? {
        let query: [CFString: Any] = [
            kSecClass: kSecClassGenericPassword,
            kSecAttrService: service,
            kSecAttrAccount: connectionID.uuidString,
            kSecReturnData: true,
            kSecMatchLimit: kSecMatchLimitOne
        ]
        var result: AnyObject?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        guard status == errSecSuccess, let data = result as? Data,
              let password = String(data: data, encoding: .utf8) else { return nil }
        // First successful read of a legacy item → re-write it with the
        // all-apps ACL so this prompt never fires again (this build or any
        // future one). Costs one prompt per connection, once, then silent.
        if !isMigrated(connectionID) {
            try? setPassword(password, for: connectionID)
        }
        return password
    }

    static func deletePassword(for connectionID: UUID) {
        let query: [CFString: Any] = [
            kSecClass: kSecClassGenericPassword,
            kSecAttrService: service,
            kSecAttrAccount: connectionID.uuidString
        ]
        _ = SecItemDelete(query as CFDictionary)
    }
}
