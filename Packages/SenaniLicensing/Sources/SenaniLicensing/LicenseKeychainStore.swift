import Foundation
import Security

/// Persists the activated license-key STRING in the macOS Keychain as a generic
/// password. No crypto here — the verifier re-checks the key on load, so a stolen
/// stored string is worthless without a real signature. No network, ever.
public struct LicenseKeychainStore: Sendable {
    let service: String
    let account: String

    public init(service: String = "in.quantana.senani.license",
                account: String = "activated-key") {
        self.service = service
        self.account = account
    }

    enum KeychainError: Error { case unexpectedStatus(OSStatus), badData }

    private func baseQuery() -> [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
    }

    public func save(_ key: String) throws {
        let data = Data(key.utf8)
        // Delete any existing item first, then add — simplest correct "upsert".
        SecItemDelete(baseQuery() as CFDictionary)
        var add = baseQuery()
        add[kSecValueData as String] = data
        add[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        let status = SecItemAdd(add as CFDictionary, nil)
        guard status == errSecSuccess else { throw KeychainError.unexpectedStatus(status) }
    }

    public func load() throws -> String? {
        var query = baseQuery()
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var item: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &item)
        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess else { throw KeychainError.unexpectedStatus(status) }
        guard let data = item as? Data, let key = String(data: data, encoding: .utf8) else {
            throw KeychainError.badData
        }
        return key
    }

    public func clear() throws {
        let status = SecItemDelete(baseQuery() as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else {
            throw KeychainError.unexpectedStatus(status)
        }
    }
}
