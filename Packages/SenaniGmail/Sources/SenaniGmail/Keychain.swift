import Foundation
import Security

public struct OAuthToken: Sendable, Equatable, Codable {
    public var accessToken: String
    public var refreshToken: String
    public var expiresAt: Date

    public init(accessToken: String, refreshToken: String, expiresAt: Date) {
        self.accessToken = accessToken
        self.refreshToken = refreshToken
        self.expiresAt = expiresAt
    }

    public func needsRefresh(now: Date, skew: TimeInterval = 60) -> Bool {
        now.addingTimeInterval(skew) >= expiresAt
    }
}

public protocol TokenStore: Sendable {
    func load() async throws -> OAuthToken?
    func save(_ token: OAuthToken) async throws
    func clear() async throws
}

public actor InMemoryTokenStore: TokenStore {
    private var token: OAuthToken?

    public init() {}

    public func load() async throws -> OAuthToken? {
        token
    }

    public func save(_ token: OAuthToken) async throws {
        self.token = token
    }

    public func clear() async throws {
        token = nil
    }
}

public struct KeychainTokenStore: TokenStore {
    private let service: String
    private let account: String

    public init(service: String = "in.quantana.senani.gmail", account: String = "default") {
        self.service = service
        self.account = account
    }

    public func load() async throws -> OAuthToken? {
        var query = baseQuery()
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne

        var item: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &item)
        if status == errSecItemNotFound {
            return nil
        }
        guard status == errSecSuccess, let data = item as? Data else {
            throw KeychainError.unhandledStatus(status)
        }
        return try JSONDecoder().decode(OAuthToken.self, from: data)
    }

    public func save(_ token: OAuthToken) async throws {
        let data = try JSONEncoder().encode(token)
        var query = baseQuery()
        let attributes = [kSecValueData as String: data]
        let updateStatus = SecItemUpdate(query as CFDictionary, attributes as CFDictionary)
        if updateStatus == errSecSuccess {
            return
        }
        guard updateStatus == errSecItemNotFound else {
            throw KeychainError.unhandledStatus(updateStatus)
        }
        query[kSecValueData as String] = data
        let addStatus = SecItemAdd(query as CFDictionary, nil)
        guard addStatus == errSecSuccess else {
            throw KeychainError.unhandledStatus(addStatus)
        }
    }

    public func clear() async throws {
        let status = SecItemDelete(baseQuery() as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else {
            throw KeychainError.unhandledStatus(status)
        }
    }

    private func baseQuery() -> [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
    }
}

public enum KeychainError: Error, Equatable {
    case unhandledStatus(OSStatus)
}
