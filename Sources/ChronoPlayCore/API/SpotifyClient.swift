import Foundation

public struct SpotifyAPIError: LocalizedError, Sendable {
    public let status: Int
    public let message: String
    public let reason: String?

    public var errorDescription: String? {
        let lower = message.lowercased()
        if reason == "PREMIUM_REQUIRED" {
            return "遙控播放需要 Spotify Premium。"
        }
        if status == 404, reason == "NO_ACTIVE_DEVICE" || lower.contains("device") {
            return "找不到可播放的裝置。請先打開 Spotify app，或在右上角選一個裝置。"
        }
        if status == 403, lower.contains("not be registered") {
            return "這個 Spotify 帳號不在開發者 app 的使用者名單中，請到 Spotify Dashboard 的 User Management 加入。"
        }
        if status == 429 {
            return "請求太頻繁，Spotify 暫時拒絕。請稍後再試。"
        }
        return "Spotify 回應錯誤（HTTP \(status)）：\(message)"
    }
}

/// Spotify Web API 的精簡 client。
/// - 401：自動 refresh token 後重試一次。
/// - 429：依 Retry-After 等待後重試（最多 3 次）。
/// - 有分頁的 endpoint 會沿著 `next` 抓完全部。
public final class SpotifyClient: Sendable {
    public static let baseURL = URL(string: "https://api.spotify.com/v1/")!

    private let tokens: TokenManager
    private let session: URLSession
    private let decoder: JSONDecoder = {
        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        return decoder
    }()

    public init(tokens: TokenManager, session: URLSession = .shared) {
        self.tokens = tokens
        self.session = session
    }

    // MARK: - 底層請求

    private func url(_ path: String, _ query: [String: String?] = [:]) -> URL {
        var components = URLComponents(url: Self.baseURL.appending(path: path), resolvingAgainstBaseURL: false)!
        let items = query.compactMap { key, value in value.map { URLQueryItem(name: key, value: $0) } }
        if !items.isEmpty { components.queryItems = items.sorted { $0.name < $1.name } }
        return components.url!
    }

    @discardableResult
    private func send(_ method: String, _ url: URL, json: (any Encodable & Sendable)? = nil) async throws -> Data {
        var didRefresh = false
        var rateLimitRetries = 0

        while true {
            let token = didRefresh ? try await tokens.forceRefresh() : try await tokens.validAccessToken()
            var request = URLRequest(url: url)
            request.httpMethod = method
            request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
            if let json {
                request.setValue("application/json", forHTTPHeaderField: "Content-Type")
                request.httpBody = try JSONEncoder().encode(json)
            } else if method != "GET" {
                request.setValue("0", forHTTPHeaderField: "Content-Length")
            }

            let (data, response) = try await session.data(for: request)
            guard let http = response as? HTTPURLResponse else { throw URLError(.badServerResponse) }

            switch http.statusCode {
            case 200..<300:
                return data
            case 401 where !didRefresh:
                didRefresh = true
                continue
            case 429 where rateLimitRetries < 3:
                rateLimitRetries += 1
                let wait = Double(http.value(forHTTPHeaderField: "Retry-After") ?? "") ?? 2
                try await Task.sleep(for: .seconds(min(wait, 30)))
                continue
            default:
                throw Self.apiError(status: http.statusCode, data: data)
            }
        }
    }

    static func apiError(status: Int, data: Data) -> SpotifyAPIError {
        struct Body: Decodable {
            struct Inner: Decodable { let message: String?; let reason: String? }
            let error: Inner
        }
        let body = try? JSONDecoder().decode(Body.self, from: data)
        return SpotifyAPIError(
            status: status,
            // 解析不了就不要把原始內容放進給使用者看的錯誤訊息。
            message: body?.error.message ?? "無法解析的回應（\(data.count) bytes）",
            reason: body?.error.reason
        )
    }

    private func get<T: Decodable>(_ url: URL, as type: T.Type = T.self) async throws -> T {
        try decoder.decode(T.self, from: try await send("GET", url))
    }

    private func allPages<Item: Decodable & Sendable>(_ first: URL, of type: Item.Type) async throws -> [Item] {
        var items: [Item] = []
        var next: URL? = first
        while let url = next {
            let page = try await get(url, as: Paging<Item>.self)
            items += page.items
            // 只跟進 Spotify API 本身的網址，避免把 Bearer token 送到別的主機。
            if let url = page.next, url.scheme != "https" || url.host() != Self.baseURL.host() {
                throw URLError(.badServerResponse)
            }
            next = page.next
        }
        return items
    }

    // MARK: - 目錄

    /// 搜尋藝人。開發模式的 search limit 上限是 10。
    public func searchArtists(_ query: String) async throws -> [Artist] {
        let response: ArtistSearchResponse = try await get(url("search", ["q": query, "type": "artist", "limit": "10"]))
        return response.artists.items
    }

    public func artist(id: String) async throws -> Artist {
        try await get(url("artists/\(id)"))
    }

    // MARK: - 播放器

    public func devices() async throws -> [Device] {
        let response: DevicesResponse = try await get(url("me/player/devices"))
        return response.devices
    }

    /// 沒有在播放任何東西時，Spotify 回 204，這裡回傳 nil。
    public func playbackState() async throws -> PlaybackState? {
        let data = try await send("GET", url("me/player", ["market": "from_token"]))
        if data.isEmpty { return nil }
        return try decoder.decode(PlaybackState.self, from: data)
    }

    public func play(uris: [String], deviceID: String?) async throws {
        struct Body: Encodable, Sendable { let uris: [String] }
        try await send("PUT", url("me/player/play", ["device_id": deviceID]), json: Body(uris: uris))
    }

    public func resume(deviceID: String?) async throws {
        try await send("PUT", url("me/player/play", ["device_id": deviceID]))
    }

    public func pause(deviceID: String?) async throws {
        try await send("PUT", url("me/player/pause", ["device_id": deviceID]))
    }

    public func addToQueue(uri: String, deviceID: String?) async throws {
        try await send("POST", url("me/player/queue", ["uri": uri, "device_id": deviceID]))
    }

    public func skipToNext(deviceID: String?) async throws {
        try await send("POST", url("me/player/next", ["device_id": deviceID]))
    }

    public func skipToPrevious(deviceID: String?) async throws {
        try await send("POST", url("me/player/previous", ["device_id": deviceID]))
    }

    public func transferPlayback(to deviceID: String, play: Bool) async throws {
        struct Body: Encodable, Sendable { let deviceIds: [String]; let play: Bool
            enum CodingKeys: String, CodingKey { case deviceIds = "device_ids", play }
        }
        try await send("PUT", url("me/player"), json: Body(deviceIds: [deviceID], play: play))
    }
}

extension SpotifyClient: CatalogAPI {
    public func artistAlbums(artistID: String, groups: String) async throws -> [Album] {
        try await allPages(url("artists/\(artistID)/albums", ["include_groups": groups, "market": "from_token"]), of: Album.self)
    }

    public func albumTracks(albumID: String) async throws -> [Track] {
        try await allPages(url("albums/\(albumID)/tracks", ["market": "from_token"]), of: Track.self)
    }
}
