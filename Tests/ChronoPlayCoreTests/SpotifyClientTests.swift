@testable import ChronoPlayCore
import Foundation
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
}

/// 假的分頁回應：每頁 2 筆、共 7 筆；後面的頁比較快回來，用來檢查結果不會依完成順序亂掉。
final class PagingProtocol: URLProtocol, @unchecked Sendable {
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
            let response = HTTPURLResponse(url: url, statusCode: 200, httpVersion: nil, headerFields: ["Content-Type": "application/json"])!
            self.client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            self.client?.urlProtocol(self, didLoad: Data(body.utf8))
            self.client?.urlProtocolDidFinishLoading(self)
        }
    }

    override func stopLoading() {}
}
