import Foundation
import Security

/// Minimal Keychain wrapper for mobile refresh credentials.
enum GonggiKeychain {
    enum Accessibility {
        /// Unlock after first device unlock — allows silent refresh while app is backgrounded
        /// after the user has unlocked once in the boot cycle (APNs / background refresh friendly).
        case afterFirstUnlockThisDeviceOnly

        var raw: CFString {
            switch self {
            case .afterFirstUnlockThisDeviceOnly:
                return kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
            }
        }
    }

    static func set(_ value: String, service: String, account: String, accessibility: Accessibility = .afterFirstUnlockThisDeviceOnly) throws {
        let data = Data(value.utf8)
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
        SecItemDelete(query as CFDictionary)
        var attrs = query
        attrs[kSecValueData as String] = data
        attrs[kSecAttrAccessible as String] = accessibility.raw
        let status = SecItemAdd(attrs as CFDictionary, nil)
        guard status == errSecSuccess else {
            throw KeychainError.unhandled(status)
        }
    }

    static func get(service: String, account: String) throws -> String? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        var item: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &item)
        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess, let data = item as? Data else {
            throw KeychainError.unhandled(status)
        }
        return String(data: data, encoding: .utf8)
    }

    static func delete(service: String, account: String) {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
        SecItemDelete(query as CFDictionary)
    }

    enum KeychainError: Error {
        case unhandled(OSStatus)
    }
}

/// Thread-safe in-memory access token for URLSession clients (actors / background).
final class MobileAuthTokenStore: @unchecked Sendable {
    static let shared = MobileAuthTokenStore()
    private let lock = NSLock()
    private var accessToken: String?

    func setAccessToken(_ token: String?) {
        lock.lock()
        accessToken = token
        lock.unlock()
    }

    func getAccessToken() -> String? {
        lock.lock()
        defer { lock.unlock() }
        return accessToken
    }
}
