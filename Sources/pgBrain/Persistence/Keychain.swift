import Foundation
import Security

/// Stores connection passwords as Keychain generic-password items keyed by connection UUID.
/// `kSecAttrAccessibleAfterFirstUnlock` so we don't prompt the user on every relaunch.
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

    static func setPassword(_ password: String, for connectionID: UUID) throws {
        let account = connectionID.uuidString
        let data = Data(password.utf8)

        // Try update first.
        let query: [CFString: Any] = [
            kSecClass: kSecClassGenericPassword,
            kSecAttrService: service,
            kSecAttrAccount: account
        ]
        let updateAttrs: [CFString: Any] = [
            kSecValueData: data,
            kSecAttrAccessible: kSecAttrAccessibleAfterFirstUnlock
        ]
        let updateStatus = SecItemUpdate(query as CFDictionary, updateAttrs as CFDictionary)
        if updateStatus == errSecSuccess { return }

        if updateStatus == errSecItemNotFound {
            var addQuery = query
            addQuery[kSecValueData] = data
            addQuery[kSecAttrAccessible] = kSecAttrAccessibleAfterFirstUnlock
            let addStatus = SecItemAdd(addQuery as CFDictionary, nil)
            if addStatus == errSecSuccess { return }
            throw KeychainError.unhandled(addStatus)
        }

        throw KeychainError.unhandled(updateStatus)
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
