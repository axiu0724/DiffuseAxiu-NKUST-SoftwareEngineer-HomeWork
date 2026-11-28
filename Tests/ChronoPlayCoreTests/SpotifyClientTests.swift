@testable import ChronoPlayCore
import Foundation
import Synchronization
import Testing

@Suite("Spotify client")
struct SpotifyClientTests {
    @Test("其餘分頁並行抓取，結果仍依 offset 排好")
    func concurrentPagesKeepOrder() async throws {
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [PagingProtocol.self]
        let tokens = TokenManager(
            clientID: "abc",
            store: InMemoryTokenStore(Tokens(accessToken: "a", refreshToken: "r", expiresAt: .distantFuture))
        )
        let client = SpotifyClient(tokens: tokens, session: URLSession(configuration: config))

        let playlists = try await client.myPlaylists()
        #expect(playlists.map(\.id) == (0..<PagingProtocol.total).map { "p\($0)" })
    }

    private func client(using protocolClass: AnyClass) -> SpotifyClient {
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [protocolClass]
        let tokens = TokenManager(
            clientID: "abc",
            store: InMemoryTokenStore(Tokens(accessToken: "a", refreshToken: "r", expiresAt: .distantFuture))
        )
        return SpotifyClient(tokens: tokens, session: URLSession(configuration: config))
    }

    @Test("好幾份分頁同時抓時，同時進行的請求總數仍不超過上限")
    func capsConcurrentRequests() async throws {
        let client = client(using: CountingPagingProtocol.self)
        async let a = client.myPlaylists()
        async let b = client.myPlaylists()
        async let c = client.myPlaylists()
        let results = try await [a, b, c]

        #expect(results.allSatisfy { $0.map(\.id) == (0..<PagingProtocol.total).map { "p\($0)" } })
        #expect(CountingPagingProtocol.maxInFlight.withLock { $0 } <= SpotifyClient.maxConcurrentRequests)
    }

    @Test("額度用完要等很久時直接報錯並說要等多久；同一組不再送出請求，其他組照常送出")
    func longRateLimitFailsFast() async throws {
        let client = client(using: RateLimitedProtocol.self)

        let error = await #expect(throws: SpotifyAPIError.self) { try await client.myPlaylists() }
        #expect(error?.status == 429)
        #expect(error?.retryAfter == .seconds(600))
        #expect(error?.errorDescription?.contains("用量額度") == true)
        #expect(error?.errorDescription?.contains("10 分鐘") == true)

        // 同一組：不送出請求，錯誤仍說明是額度用完
        let again = await #expect(throws: SpotifyAPIError.self) { try await client.myPlaylists() }
        #expect(again?.reason == "QUOTA_EXCEEDED")
        #expect(RateLimitedProtocol.requests.withLock { $0 } == 1)

        // 別組（播放狀態）不受影響，照常送出
        await #expect(throws: SpotifyAPIError.self) { try await client.playbackState() }
        #expect(RateLimitedProtocol.requests.withLock { $0 } == 2)
    }

    @Test("額度分組依路徑的第一段，me/ 底下再多看一段")
    func quotaGroups() {
        func group(_ path: String) -> String { SpotifyClient.quotaGroup(for: SpotifyClient.baseURL.appending(path: path)) }
        #expect(group("artists/x/albums") == "artists")
        #expect(group("albums/x/tracks") == "albums")
        #expect(group("me/player") == "me/player")
        #expect(group("me/player/queue") == "me/player")
        #expect(group("me/playlists") == "me/playlists")
        #expect(group("me") == "me")
    }
}

/// 和 PagingProtocol 一樣回分頁，另外記錄同時進行的請求數最多到多少。
final class CountingPagingProtocol: PagingProtocol, @unchecked Sendable {
    static let inFlight = Mutex(0)
    static let maxInFlight = Mutex(0)

    override func startLoading() {
        let now = Self.inFlight.withLock { $0 += 1; return $0 }
        Self.maxInFlight.withLock { $0 = max($0, now) }
        super.startLoading()
    }

    override func finishLoading() {
        Self.inFlight.withLock { $0 -= 1 }
        super.finishLoading()
    }
}

/// 每個請求都回 429（額度用完）、Retry-After 600 秒，並記錄收到幾個請求。
final class RateLimitedProtocol: URLProtocol, @unchecked Sendable {
    static let requests = Mutex(0)

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        Self.requests.withLock { $0 += 1 }
        let response = HTTPURLResponse(url: request.url!, statusCode: 429, httpVersion: nil, headerFields: ["Retry-After": "600"])!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Data(#"{"error":{"status":429,"message":"Too many requests","reason":"QUOTA_EXCEEDED"}}"#.utf8))
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}
}

/// 假的分頁回應：每頁 2 筆、共 7 筆；後面的頁比較快回來，用來檢查結果不會依完成順序亂掉。
class PagingProtocol: URLProtocol, @unchecked Sendable {
    static let total = 7
    static let limit = 2

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        let url = request.url!
        let query = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems ?? []
        let offset = query.first { $0.name == "offset" }?.value.flatMap { Int($0) } ?? 0
        let total = Self.total, limit = Self.limit

        let items = (offset..<min(offset + limit, total))
            .map { #"{"id":"p\#($0)","name":"p\#($0)","uri":"spotify:playlist:p\#($0)","owner":{"id":"me"}}"# }
            .joined(separator: ",")
        let next = offset + limit < total
            ? #""https://api.spotify.com/v1/me/playlists?limit=\#(limit)&offset=\#(offset + limit)""#
            : "null"
        let body = #"{"items":[\#(items)],"next":\#(next),"total":\#(total)}"#

        DispatchQueue.global().asyncAfter(deadline: .now() + .milliseconds(20 * (total - offset))) {
            self.finishLoading()
            let response = HTTPURLResponse(url: url, statusCode: 200, httpVersion: nil, headerFields: ["Content-Type": "application/json"])!
            self.client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            self.client?.urlProtocol(self, didLoad: Data(body.utf8))
            self.client?.urlProtocolDidFinishLoading(self)
        }
    }

    /// 回應送出前呼叫，子類別用來記錄請求結束。
    func finishLoading() {}

    override func stopLoading() {}
}
