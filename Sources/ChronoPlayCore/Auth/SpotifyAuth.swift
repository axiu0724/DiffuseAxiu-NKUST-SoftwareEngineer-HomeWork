import Foundation

public enum SpotifyAuthError: LocalizedError {
    case missingClientID
    case stateMismatch
    case missingCode(String?)
    case notLoggedIn
    case tokenRequestFailed(Int, String)

    public var errorDescription: String? {
        switch self {
        case .missingClientID: "請先在設定裡填入 Spotify Client ID。"
        case .stateMismatch: "登入回應的 state 不符，已中止登入。"
        case .missingCode(let error): "Spotify 沒有回傳授權碼\(error.map { "（\($0)）" } ?? "")。"
        case .notLoggedIn: "尚未登入 Spotify。"
        case .tokenRequestFailed(let status, let body): "取得 token 失敗（HTTP \(status)）：\(body)"
        }
    }
}

/// Spotify 的 Authorization Code + PKCE 流程。開瀏覽器的部分交給 UI（ASWebAuthenticationSession）。
public struct SpotifyAuthConfig: Sendable {
    public static let redirectURI = "chronoplay://callback"
    public static let callbackScheme = "chronoplay"
    public static let scopes = [
        "user-read-playback-state",
        "user-modify-playback-state",
        "user-read-currently-playing",
        // 讀取自己的播放清單與已按讚的歌曲（顯示清單、標示歌曲已收藏）
        "playlist-read-private",
        "playlist-read-collaborative",
        "user-library-read",
    ]

    /// 已授權的 scope 是否涵蓋目前需要的全部。不知道（舊版 token）時視為不足。
    public static func covers(_ granted: Set<String>?) -> Bool {
        guard let granted else { return false }
        return Set(scopes).isSubset(of: granted)
    }

    public let clientID: String

    public init(clientID: String) {
        self.clientID = clientID
    }

    public func authorizeURL(pkce: PKCE, state: String) -> URL {
        var components = URLComponents(string: "https://accounts.spotify.com/authorize")!
        components.queryItems = [
            URLQueryItem(name: "client_id", value: clientID),
            URLQueryItem(name: "response_type", value: "code"),
            URLQueryItem(name: "redirect_uri", value: Self.redirectURI),
            URLQueryItem(name: "code_challenge_method", value: "S256"),
            URLQueryItem(name: "code_challenge", value: pkce.challenge),
            URLQueryItem(name: "state", value: state),
            URLQueryItem(name: "scope", value: Self.scopes.joined(separator: " ")),
        ]
        return components.url!
    }

    /// 從 redirect 回來的網址取出授權碼，並檢查 state。
    public static func code(from callback: URL, expectedState: String) throws -> String {
        let items = URLComponents(url: callback, resolvingAgainstBaseURL: false)?.queryItems ?? []
        let value = { (name: String) in items.first { $0.name == name }?.value }
        guard value("state") == expectedState else { throw SpotifyAuthError.stateMismatch }
        guard let code = value("code") else { throw SpotifyAuthError.missingCode(value("error")) }
        return code
    }
}

/// 保管 token，過期時自動用 refresh token 換新的。
public actor TokenManager {
    private struct TokenResponse: Decodable {
        let accessToken: String
        let expiresIn: Int
        let refreshToken: String?
        let scope: String?
    }

    private let clientID: String
    private let store: any TokenStore
    private let session: URLSession
    private var tokens: Tokens?
    private var refreshTask: Task<Tokens, Error>?
    /// 每次登出就加一。refresh 送出後若已登出，回來的 token 不能再存回去。
    private var generation = 0

    public init(clientID: String, store: any TokenStore, session: URLSession = .shared) {
        self.clientID = clientID
        self.store = store
        self.session = session
        self.tokens = store.load()
    }

    public var isLoggedIn: Bool { tokens != nil }

    public var grantedScopes: Set<String>? { tokens?.grantedScopes }

    /// 用授權碼換第一組 token。
    public func exchange(code: String, pkce: PKCE) async throws {
        let tokens = try await requestTokens([
            "grant_type": "authorization_code",
            "code": code,
            "redirect_uri": SpotifyAuthConfig.redirectURI,
            "client_id": clientID,
            "code_verifier": pkce.verifier,
        ], previous: nil)
        try set(tokens)
    }

    public func validAccessToken() async throws -> String {
        guard let tokens else { throw SpotifyAuthError.notLoggedIn }
        if !tokens.isExpired() { return tokens.accessToken }
        return try await refresh().accessToken
    }

    /// 收到 401 時呼叫：不管有沒有過期都強制換新。
    public func forceRefresh() async throws -> String {
        try await refresh().accessToken
    }

    public func logout() {
        generation += 1
        refreshTask = nil
        tokens = nil
        store.clear()
    }

    private func set(_ tokens: Tokens) throws {
        self.tokens = tokens
        try store.save(tokens)
    }

    private func refresh() async throws -> Tokens {
        // 多個請求同時發現過期時，只送一次 refresh。
        if let refreshTask { return try await refreshTask.value }
        guard let current = tokens else { throw SpotifyAuthError.notLoggedIn }
        let task = Task {
            try await requestTokens([
                "grant_type": "refresh_token",
                "refresh_token": current.refreshToken,
                "client_id": clientID,
            ], previous: current)
        }
        refreshTask = task
        let startGeneration = generation
        defer { if generation == startGeneration { refreshTask = nil } }
        do {
            let new = try await task.value
            // 等待回應的期間使用者登出了：丟掉這組 token，不要寫回 Keychain。
            guard generation == startGeneration else { throw SpotifyAuthError.notLoggedIn }
            try set(new)
            return new
        } catch SpotifyAuthError.tokenRequestFailed(let status, let body) where status == 400 {
            // refresh token 失效（例如使用者撤銷授權）：清掉，請使用者重新登入。
            if generation == startGeneration { logout() }
            throw SpotifyAuthError.tokenRequestFailed(status, body)
        }
    }

    private func requestTokens(_ form: [String: String], previous: Tokens?) async throws -> Tokens {
        var request = URLRequest(url: URL(string: "https://accounts.spotify.com/api/token")!)
        request.httpMethod = "POST"
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        request.httpBody = Self.formEncode(form).data(using: .utf8)

        let (data, response) = try await session.data(for: request)
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        guard status == 200 else {
            throw SpotifyAuthError.tokenRequestFailed(status, Self.errorSummary(data))
        }
        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        let body = try decoder.decode(TokenResponse.self, from: data)
        guard let refreshToken = body.refreshToken ?? previous?.refreshToken else {
            throw SpotifyAuthError.tokenRequestFailed(status, "回應中沒有 refresh_token")
        }
        return Tokens(
            accessToken: body.accessToken,
            refreshToken: refreshToken,
            expiresAt: Date.now.addingTimeInterval(TimeInterval(body.expiresIn)),
            // refresh 的回應沒有 scope 時沿用原本的
            scope: body.scope ?? previous?.scope
        )
    }

    /// 只取 OAuth 錯誤回應的 error／error_description，不把原始 body 放進錯誤訊息。
    static func errorSummary(_ data: Data) -> String {
        struct Body: Decodable { let error: String; let errorDescription: String? }
        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        guard let body = try? decoder.decode(Body.self, from: data) else {
            return "無法解析的回應（\(data.count) bytes）"
        }
        return body.errorDescription.map { "\(body.error)：\($0)" } ?? body.error
    }

    static func formEncode(_ form: [String: String]) -> String {
        var allowed = CharacterSet.alphanumerics
        allowed.insert(charactersIn: "-._~")
        return form
            .sorted { $0.key < $1.key }
            .map { "\($0.key)=\($0.value.addingPercentEncoding(withAllowedCharacters: allowed) ?? $0.value)" }
            .joined(separator: "&")
    }
}
