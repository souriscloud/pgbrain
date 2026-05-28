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

    /// Empty-flags access control — "available when the device is
    /// unlocked, no user presence required, no per-binary ACL". This
    /// is what kills the recurring `Always Allow / Allow / Deny`
    /// dialog after a Sparkle update.
    private static func makeAccessControl() -> SecAccessControl? {
        var error: Unmanaged<CFError>?
        let access = SecAccessControlCreateWithFlags(
            nil,
            kSecAttrAccessibleAfterFirstUnlock,
            [],
            &error
        )
        if let err = error?.takeRetainedValue() {
            // Log and fall through with nil — caller will write the
            // item without an ACL, which is the same behaviour as the
            // pre-rewrite code (just no improvement).
            NSLog("pgBrain: SecAccessControlCreateWithFlags failed: \(err)")
            return nil
        }
        return access
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
        if let access = makeAccessControl() {
            addQuery[kSecAttrAccessControl] = access
            // kSecAttrAccessControl and kSecAttrAccessible are mutually
            // exclusive — accessibility is baked into the access control.
        } else {
            addQuery[kSecAttrAccessible] = kSecAttrAccessibleAfterFirstUnlock
        }
        let addStatus = SecItemAdd(addQuery as CFDictionary, nil)
        if addStatus == errSecSuccess { return }
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
        guard status == errSecSuccess, let data = result as? Data else { return nil }
        return String(data: data, encoding: .utf8)
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
