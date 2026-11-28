import Foundation

public struct SpotifyAPIError: LocalizedError, Sendable {
    public let status: Int
    public let message: String
    public let reason: String?
    /// 429 時 Spotify 要求等待的時間
    public var retryAfter: Duration? = nil

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
            // 開發模式有兩種限制：短時間內請求太多（速率限制），以及某類 API 的用量額度用完（QUOTA_EXCEEDED）
            let what = reason == "QUOTA_EXCEEDED"
                ? "這類資料的 Spotify 開發模式用量額度暫時用完了。"
                : "請求太頻繁，Spotify 暫時拒絕。"
            guard let seconds = retryAfter?.components.seconds, seconds > 60 else {
                return what + "請稍後再試。"
            }
            let minutes = (seconds + 59) / 60
            let wait = minutes < 120 ? "\(minutes) 分鐘" : "\((minutes + 59) / 60) 小時"
            return what + "大約 \(wait)後再試。"
        }
        return "Spotify 回應錯誤（HTTP \(status)）：\(message)"
    }
}

/// 所有請求共用的閘門：限制同時進行的請求數，並在 Spotify 回 429 後讓同一組的請求一起等，不要各自去撞限流。
/// Spotify 是用 30 秒的滾動視窗計算請求數，請求越集中越容易超過上限，所以不管呼叫端有幾層並行，總數都由這裡控制。
/// 開發模式的用量額度則是依 API 分桶計算，所以被擋時只擋同一組（見 `SpotifyClient.quotaGroup`）。
actor RequestGate {
    struct Block {
        let until: ContinuousClock.Instant
        let reason: String?
    }

    private let limit: Int
    private var running = 0
    private var waiters: [CheckedContinuation<Void, Never>] = []
    private var blocks: [String: Block] = [:]

    init(limit: Int) { self.limit = limit }

    func acquire() async {
        if running < limit {
            running += 1
            return
        }
        // 名額由 release 直接轉交，running 不變
        await withCheckedContinuation { waiters.append($0) }
    }

    func release() {
        if waiters.isEmpty {
            running -= 1
        } else {
            waiters.removeFirst().resume()
        }
    }

    func block(_ group: String, for duration: Duration, reason: String?) {
        let until = ContinuousClock.now + duration
        if blocks[group].map({ until > $0.until }) ?? true { blocks[group] = Block(until: until, reason: reason) }
    }

    /// 這一組還要等多久才能再送請求，以及被擋的原因；沒有被擋時回傳 nil。
    func remainingBlock(_ group: String) -> (Duration, reason: String?)? {
        guard let block = blocks[group] else { return nil }
        let remaining = block.until - .now
        guard remaining > .zero else {
            blocks[group] = nil
            return nil
        }
        return (remaining, block.reason)
    }
}

/// Spotify Web API 的精簡 client。
/// - 401：自動 refresh token 後重試一次。
/// - 429：同一組的請求一起依 Retry-After 等待後重試（最多 3 次）；要等超過 30 秒就直接報錯，告訴使用者要等多久。
/// - 同時進行的請求最多 4 個。
/// - 有分頁的 endpoint 會沿著 `next` 抓完全部。
public final class SpotifyClient: Sendable {
    public static let baseURL = URL(string: "https://api.spotify.com/v1/")!
    /// 同時進行的請求上限（所有呼叫端加起來）
    static let maxConcurrentRequests = 4
    /// 被限流時最多願意等多久；超過就直接報錯
    static let maxRateLimitWait: Duration = .seconds(30)

    private let tokens: TokenManager
    private let session: URLSession
    private let gate = RequestGate(limit: maxConcurrentRequests)
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
        let group = Self.quotaGroup(for: url)

        while true {
            try await waitForRateLimit(group)
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

            await gate.acquire()
            let data: Data, response: URLResponse
            do {
                try Task.checkCancellation()
                (data, response) = try await session.data(for: request)
            } catch {
                await gate.release()
                throw error
            }
            await gate.release()
            guard let http = response as? HTTPURLResponse else { throw URLError(.badServerResponse) }

            switch http.statusCode {
            case 200..<300:
                return data
            case 401 where !didRefresh:
                didRefresh = true
                continue
            case 429:
                let retryAfter = Duration.seconds(Double(http.value(forHTTPHeaderField: "Retry-After") ?? "") ?? 2)
                var error = Self.apiError(status: 429, data: data)
                error.retryAfter = retryAfter
                await gate.block(group, for: retryAfter, reason: error.reason)
                guard rateLimitRetries < 3, retryAfter <= Self.maxRateLimitWait else { throw error }
                rateLimitRetries += 1
                continue  // 下一輪開頭會等到限流解除
            default:
                throw Self.apiError(status: http.statusCode, data: data)
            }
        }
    }

    /// 這一組被限流時先等到解除再送；要等太久就不送了，直接報錯。
    private func waitForRateLimit(_ group: String) async throws {
        guard let (remaining, reason) = await gate.remainingBlock(group) else { return }
        guard remaining <= Self.maxRateLimitWait else {
            throw SpotifyAPIError(status: 429, message: "Too many requests", reason: reason, retryAfter: remaining)
        }
        try await Task.sleep(for: remaining)
    }

    /// Spotify 把 API 分成好幾個用量額度桶，但沒有公開怎麼分。這裡用路徑的第一段粗略分組
    /// （`me/` 底下再多看一段），例如 artists、albums、me/player、me/playlists、playlists、search。
    /// 一組被擋時只讓同一組等，藝人作品的額度用完，播放控制和清單照樣能用。
    static func quotaGroup(for url: URL) -> String {
        let parts = url.path().split(separator: "/").dropFirst()  // 去掉 v1
        guard let first = parts.first else { return "" }
        if first == "me", parts.count > 1 { return "me/\(parts[parts.index(after: parts.startIndex)])" }
        return String(first)
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

    /// 同一份分頁資料最多同時抓幾頁。
    static let maxConcurrentPageRequests = 4

    /// 抓完第一頁後，依 `total` 和 `next` 網址裡的 offset／limit 算出其餘分頁，用有限並行一起抓，再依順序接起來。
    /// 拿不到這些資訊時，退回一頁一頁跟著 `next` 走。
    private func allPages<Item: Decodable & Sendable>(_ first: URL, of type: Item.Type) async throws -> [Item] {
        let firstPage = try await get(first, as: Paging<Item>.self)
        guard let next = try Self.checkedNext(of: firstPage) else { return firstPage.items }

        guard let total = firstPage.total,
              var components = URLComponents(url: next, resolvingAgainstBaseURL: false),
              let query = components.queryItems,
              let offset = query.first(where: { $0.name == "offset" })?.value.flatMap({ Int($0) }),
              let limit = query.first(where: { $0.name == "limit" })?.value.flatMap({ Int($0) }), limit > 0
        else {
            var items = firstPage.items
            var url: URL? = next
            while let current = url {
                let page = try await get(current, as: Paging<Item>.self)
                items += page.items
                url = try Self.checkedNext(of: page)
            }
            return items
        }

        // 只改 offset，主機和其他參數都沿用已檢查過的 next 網址。
        var urls: [URL] = []
        for pageOffset in stride(from: offset, to: total, by: limit) {
            components.queryItems = query.map { $0.name == "offset" ? URLQueryItem(name: "offset", value: String(pageOffset)) : $0 }
            guard let url = components.url else { throw URLError(.badURL) }
            urls.append(url)
        }

        var pages = [[Item]](repeating: [], count: urls.count)
        try await withThrowingTaskGroup(of: (Int, [Item]).self) { group in
            var nextIndex = 0
            func addTask() {
                let index = nextIndex
                let url = urls[index]
                nextIndex += 1
                group.addTask {
                    let page = try await self.get(url, as: Paging<Item>.self)
                    return (index, page.items)
                }
            }
            for _ in 0..<min(Self.maxConcurrentPageRequests, urls.count) { addTask() }
            while let (index, items) = try await group.next() {
                pages[index] = items
                if nextIndex < urls.count { addTask() }
            }
        }
        return firstPage.items + pages.joined()
    }

    /// 只跟進 Spotify API 本身的網址，避免把 Bearer token 送到別的主機。
    private static func checkedNext<Item: Decodable & Sendable>(of page: Paging<Item>) throws -> URL? {
        guard let url = page.next else { return nil }
        guard url.scheme == "https", url.host() == baseURL.host() else { throw URLError(.badServerResponse) }
        return url
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
        try await allPages(url("albums/\(albumID)/tracks", ["limit": "50", "market": "from_token"]), of: Track.self)
    }
}

extension SpotifyClient: LibraryAPI {
    public func currentUserID() async throws -> String {
        let user: CurrentUser = try await get(url("me"))
        return user.id
    }

    public func myPlaylists() async throws -> [Playlist] {
        try await allPages(url("me/playlists", ["limit": "50"]), of: Playlist.self)
    }

    /// 2026 年 2 月起的新路徑（舊的 `/tracks` 已移除）。
    public func playlistItems(playlistID: String) async throws -> [LibraryItem] {
        try await allPages(
            url("playlists/\(playlistID)/items", ["limit": "50", "market": "from_token", "additional_types": "track"]),
            of: LibraryItem.self
        )
    }

    public func likedItems() async throws -> [LibraryItem] {
        try await allPages(url("me/tracks", ["limit": "50", "market": "from_token"]), of: LibraryItem.self)
    }

    /// 取代已移除的 `GET /me/tracks/contains`。
    public func libraryContains(uris: [String]) async throws -> [Bool] {
        guard !uris.isEmpty else { return [] }
        precondition(uris.count <= LibraryLoader.containsBatchSize)
        return try await get(url("me/library/contains", ["uris": uris.joined(separator: ",")]))
    }
}
