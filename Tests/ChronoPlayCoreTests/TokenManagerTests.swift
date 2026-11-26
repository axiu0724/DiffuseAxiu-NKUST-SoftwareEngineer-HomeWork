@testable import ChronoPlayCore
import Foundation
import Testing

@Suite("Token 管理")
struct TokenManagerTests {
    @Test("refresh 途中登出，新 token 不會被寫回")
    func logoutDuringRefresh() async throws {
        let expired = Tokens(accessToken: "old", refreshToken: "old-refresh", expiresAt: .distantPast)
        let store = InMemoryTokenStore(expired)
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [GatedTokenProtocol.self]
        let manager = TokenManager(clientID: "abc", store: store, session: URLSession(configuration: config))

        // token 已過期，所以這裡會送出 refresh，並卡在 GatedTokenProtocol 等待放行。
        let refresh = Task { try await manager.validAccessToken() }
        await GatedTokenProtocol.gate.waitUntilArrived()

        await manager.logout()
        await GatedTokenProtocol.gate.open()

        do {
            _ = try await refresh.value
            Issue.record("登出後的 refresh 不應該回傳 token")
        } catch SpotifyAuthError.notLoggedIn {
            // 預期：伺服器有回新 token，但因為已登出而被丟掉
        }
        #expect(store.load() == nil)
        #expect(await manager.isLoggedIn == false)
    }
}

/// 攔截 token 請求：先通知測試「請求到了」，等測試放行才回傳一組新 token。
final class GatedTokenProtocol: URLProtocol, @unchecked Sendable {
    static let gate = Gate()

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        Task {
            await Self.gate.markArrived()
            await Self.gate.waitUntilOpen()
            let body = #"{"access_token":"new-access","expires_in":3600,"refresh_token":"new-refresh"}"#
            let response = HTTPURLResponse(
                url: request.url!, statusCode: 200, httpVersion: nil,
                headerFields: ["Content-Type": "application/json"]
            )!
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: Data(body.utf8))
            client?.urlProtocolDidFinishLoading(self)
        }
    }

    override func stopLoading() {}

    actor Gate {
        private var arrived = false
        private var isOpen = false
        private var arrivedWaiters: [CheckedContinuation<Void, Never>] = []
        private var openWaiters: [CheckedContinuation<Void, Never>] = []

        func markArrived() {
            arrived = true
            arrivedWaiters.forEach { $0.resume() }
            arrivedWaiters = []
        }

        func waitUntilArrived() async {
            if arrived { return }
            await withCheckedContinuation { arrivedWaiters.append($0) }
        }

        func open() {
            isOpen = true
            openWaiters.forEach { $0.resume() }
            openWaiters = []
        }

        func waitUntilOpen() async {
            if isOpen { return }
            await withCheckedContinuation { openWaiters.append($0) }
        }
    }
}
