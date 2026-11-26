import Foundation
import Security

public struct Tokens: Codable, Sendable, Equatable {
    public var accessToken: String
    public var refreshToken: String
    public var expiresAt: Date

    public init(accessToken: String, refreshToken: String, expiresAt: Date) {
        self.accessToken = accessToken
        self.refreshToken = refreshToken
        self.expiresAt = expiresAt
    }

    /// 提早 60 秒視為過期，避免請求途中失效。
    public func isExpired(now: Date = .now) -> Bool {
        expiresAt.timeIntervalSince(now) < 60
    }
}

public protocol TokenStore: Sendable {
    func load() -> Tokens?
    func save(_ tokens: Tokens)
    func clear()
}

/// 把 token 存在使用者的 Keychain（login keychain）。
public struct KeychainTokenStore: TokenStore {
    private let service: String
    private let account = "spotify-tokens"

    public init(service: String = "ChronoPlay") {
        self.service = service
    }

    private var baseQuery: [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
    }

    public func load() -> Tokens? {
        var query = baseQuery
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess,
              let data = result as? Data
        else { return nil }
        return try? JSONDecoder().decode(Tokens.self, from: data)
    }

    public func save(_ tokens: Tokens) {
        guard let data = try? JSONEncoder().encode(tokens) else { return }
        let update = [kSecValueData as String: data]
        if SecItemUpdate(baseQuery as CFDictionary, update as CFDictionary) == errSecItemNotFound {
            var add = baseQuery
            add[kSecValueData as String] = data
            SecItemAdd(add as CFDictionary, nil)
        }
    }

    public func clear() {
        SecItemDelete(baseQuery as CFDictionary)
    }
}

/// 測試用的記憶體 token 儲存。
public final class InMemoryTokenStore: TokenStore, @unchecked Sendable {
    private let lock = NSLock()
    private var tokens: Tokens?

    public init(_ tokens: Tokens? = nil) {
        self.tokens = tokens
    }

    public func load() -> Tokens? { lock.withLock { tokens } }
    public func save(_ tokens: Tokens) { lock.withLock { self.tokens = tokens } }
    public func clear() { lock.withLock { tokens = nil } }
}
