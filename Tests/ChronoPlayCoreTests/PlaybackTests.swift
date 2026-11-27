@testable import ChronoPlayCore
import Foundation
import Testing

@Suite("連續播放計畫")
struct SequencePlanTests {
    let uris = (0..<8).map { "spotify:track:\($0)" }

    @Test("開始時只送出一段 window")
    func startSendsWindow() {
        let (plan, actions) = SequencePlan.start(uris: uris, at: 2, windowSize: 3)
        #expect(actions == [.play(Array(uris[2..<5]))])
        #expect(plan.currentIndex == 2)
        #expect(plan.windowEnd == 5)
    }

    @Test("在 window 最後一首之前不補佇列，避免插隊")
    func noQueueBeforeWindowEnd() {
        var (plan, _) = SequencePlan.start(uris: uris, at: 0, windowSize: 3)
        #expect(plan.observe(currentURI: uris[0]) == [])
        #expect(plan.observe(currentURI: uris[1]) == [])
        #expect(plan.currentIndex == 1)
    }

    @Test("播到 window 最後一首時補上後面的歌，並維持 lookahead")
    func queuesAtWindowEnd() {
        var (plan, _) = SequencePlan.start(uris: uris, at: 0, windowSize: 3, lookahead: 2)
        _ = plan.observe(currentURI: uris[0])
        #expect(plan.observe(currentURI: uris[2]) == [.enqueue(uris[3]), .enqueue(uris[4])])
        // 播到補進去的第一首，再補一首
        #expect(plan.observe(currentURI: uris[3]) == [.enqueue(uris[5])])
        // 同一首重複觀察不會重複補
        #expect(plan.observe(currentURI: uris[3]) == [])
        #expect(plan.observe(currentURI: uris[4]) == [.enqueue(uris[6])])
        #expect(plan.observe(currentURI: uris[5]) == [.enqueue(uris[7])])
        #expect(plan.observe(currentURI: uris[6]) == [])
        #expect(plan.queuedEnd == uris.count)
    }

    @Test("整份清單播完後暫停，不讓推薦歌曲接手")
    func pausesAfterLastTrack() {
        var (plan, _) = SequencePlan.start(uris: uris, at: 6, windowSize: 10)
        _ = plan.observe(currentURI: uris[6])
        _ = plan.observe(currentURI: uris[7])
        #expect(plan.observe(currentURI: "spotify:track:recommended") == [.pause])
        #expect(plan.status == .finished)
    }

    @Test("使用者在官方 app 換歌時停止接管")
    func detachesWhenUserPlaysSomethingElse() {
        var (plan, _) = SequencePlan.start(uris: uris, at: 0, windowSize: 3)
        _ = plan.observe(currentURI: uris[0])
        #expect(plan.observe(currentURI: "spotify:track:else") == [])
        #expect(plan.status == .detached)
        // 離開後不再做任何事
        #expect(plan.observe(currentURI: uris[2]) == [])
    }

    @Test("剛開始時容忍幾次舊狀態")
    func startupGrace() {
        var (plan, _) = SequencePlan.start(uris: uris, at: 0, windowSize: 3)
        for _ in 0..<(SequencePlan.startupGraceObservations - 1) {
            _ = plan.observe(currentURI: "spotify:track:previous-song")
        }
        #expect(plan.status == .playing)
        _ = plan.observe(currentURI: uris[0])
        #expect(plan.hasConfirmedStart)
    }

    @Test("開始後一直對不上就放棄")
    func startupGraceGivesUp() {
        var (plan, _) = SequencePlan.start(uris: uris, at: 0, windowSize: 3)
        for _ in 0..<SequencePlan.startupGraceObservations {
            _ = plan.observe(currentURI: "spotify:track:previous-song")
        }
        #expect(plan.status == .detached)
    }

    @Test("按上一首回到前面的歌")
    func previousTrack() {
        var (plan, _) = SequencePlan.start(uris: uris, at: 0, windowSize: 5)
        _ = plan.observe(currentURI: uris[2])
        _ = plan.observe(currentURI: uris[1])
        #expect(plan.currentIndex == 1)
        #expect(plan.status == .playing)
    }

    @Test("重複出現的 URI 會對到往後最近的位置")
    func duplicateURIs() {
        let dup = ["a", "b", "a", "c"]
        var (plan, _) = SequencePlan.start(uris: dup, at: 0, windowSize: 4)
        _ = plan.observe(currentURI: "a")
        _ = plan.observe(currentURI: "b")
        _ = plan.observe(currentURI: "a")
        #expect(plan.currentIndex == 2)
    }

    @Test("window 大於清單時不補佇列")
    func windowCoversAll() {
        var (plan, actions) = SequencePlan.start(uris: uris, at: 0, windowSize: 100)
        #expect(actions == [.play(uris)])
        #expect(plan.observe(currentURI: uris[7]) == [])
    }
}

@Suite("播放控制器")
@MainActor
struct PlaybackControllerTests {
    func entries(_ count: Int) -> [DiscographyEntry] {
        let album = Fixture.album("a", date: "2000-01-01")
        return (0..<count).map { Fixture.entry(album, Fixture.track("t\($0)", number: $0 + 1)) }
    }

    @Test("跨過 window 邊界時把下一首加進佇列")
    func crossesWindowBoundary() async {
        let player = FakePlayer()
        let controller = PlaybackController(api: player)
        let list = entries(5)

        await controller.start(entries: list, at: 0, windowSize: 2)
        #expect(await player.calls == [.play([list[0].track.uri, list[1].track.uri])])

        await player.setCurrent(uri: list[1].track.uri)
        await controller.refresh()
        #expect(await player.calls.dropFirst() == [.queue(list[2].track.uri), .queue(list[3].track.uri)])
        #expect(controller.currentEntry == list[1])
    }

    @Test("輪詢的暫時錯誤在下次成功後自動清除")
    func pollingErrorClears() async {
        let player = FakePlayer()
        await player.setStateError(URLError(.notConnectedToInternet))
        let controller = PlaybackController(api: player)

        await controller.refresh()
        #expect(controller.lastError != nil)

        await player.setStateError(nil)
        await controller.refresh()
        #expect(controller.lastError == nil)
    }

    @Test("播放失敗時取消計畫並顯示錯誤")
    func playFailure() async {
        let player = FakePlayer()
        await player.setPlayError(SpotifyAPIError(status: 403, message: "Premium required", reason: "PREMIUM_REQUIRED"))
        let controller = PlaybackController(api: player)

        await controller.start(entries: entries(3), at: 0, windowSize: 10)
        #expect(controller.plan == nil)
        #expect(controller.lastError == "遙控播放需要 Spotify Premium。")
    }

    @Test("沒在連續播放時，暫停與背景會放慢輪詢；連續播放中在背景也維持原本頻率")
    func pollingSlowsDownWhenIdle() async {
        let player = FakePlayer()
        let controller = PlaybackController(api: player)

        await player.setCurrent(uri: "other", isPlaying: false)
        #expect(await controller.refresh() == .seconds(10))
        controller.isAppActive = false
        #expect(await controller.refresh() == .seconds(30))

        await controller.start(entries: entries(3), at: 0, windowSize: 3)
        #expect(await controller.refresh() == .seconds(3))
    }

    @Test("Spotify 播的是同一首歌在另一個專輯版本上的 URI 時，仍對到清單裡那首，不會離開連續播放")
    func matchesSameRecordingWithDifferentURI() async {
        let player = FakePlayer()
        let controller = PlaybackController(api: player)
        let list = entries(4)
        await controller.start(entries: list, at: 0, windowSize: 4)

        let track = list[1].track
        await player.setCurrent(item: PlayingItem(uri: "spotify:track:other-version", name: track.name,
                                                  durationMs: track.durationMs, artists: track.artists))
        for _ in 0..<SequencePlan.startupGraceObservations { await controller.refresh() }
        #expect(controller.plan?.status == .playing)
        #expect(controller.currentEntry == list[1])

        // 歌名和藝人一樣但長度不同，就不是同一段錄音：視為使用者換了歌
        await player.setCurrent(item: PlayingItem(uri: "spotify:track:remix", name: track.name,
                                                  durationMs: track.durationMs + 1000, artists: track.artists))
        await controller.refresh()
        #expect(controller.plan?.status == .detached)
    }

    @Test("背景閒置時開始連續播放，輪詢不用等滿 30 秒，直接改用連續播放的間隔")
    func startReschedulesSlowPolling() async throws {
        let player = FakePlayer()
        await player.setCurrent(uri: "other", isPlaying: false)
        let controller = PlaybackController(api: player)
        controller.isAppActive = false
        controller.startPolling()
        defer { controller.stopPolling() }

        func waitForPoll(before limit: Duration) async throws -> Bool {
            for _ in 0..<200 {
                if let next = controller.nextPollAt, next < .now + limit { return true }
                try await Task.sleep(for: .milliseconds(10))
            }
            return false
        }
        #expect(try await waitForPoll(before: .seconds(31)))
        #expect(controller.nextPollAt.map { $0 > .now + .seconds(20) } == true)

        await controller.start(entries: entries(3), at: 0, windowSize: 3)
        #expect(try await waitForPoll(before: .seconds(4)))
    }
}

@Suite("PKCE")
struct PKCETests {
    @Test("RFC 7636 附錄 B 的測試向量")
    func rfcVector() {
        let pkce = PKCE(verifier: "dBjftJeZ4CVP-mB92K27uhbUJU1p1r_wW1gFWFOEjXk")
        #expect(pkce.challenge == "E9Melhoa2OwvFrEMTJguCHaoeK1t8URWbuGJSstw-cM")
    }

    @Test("產生的 verifier 長度與字元符合規範")
    func generatedVerifier() {
        let verifier = PKCE.generate().verifier
        #expect((43...128).contains(verifier.count))
        #expect(verifier.allSatisfy { $0.isLetter || $0.isNumber || "-._~".contains($0) })
    }

    @Test("授權網址帶有必要參數")
    func authorizeURL() {
        let url = SpotifyAuthConfig(clientID: "abc").authorizeURL(pkce: PKCE(verifier: "v"), state: "s")
        let query = url.query() ?? ""
        #expect(query.contains("client_id=abc"))
        #expect(query.contains("code_challenge_method=S256"))
        #expect(query.contains("redirect_uri=chronoplay://callback"))
    }

    @Test("從 callback 取出授權碼，state 不符時拒絕")
    func callbackParsing() throws {
        let url = URL(string: "chronoplay://callback?code=XYZ&state=s1")!
        #expect(try SpotifyAuthConfig.code(from: url, expectedState: "s1") == "XYZ")
        #expect(throws: SpotifyAuthError.self) {
            try SpotifyAuthConfig.code(from: url, expectedState: "other")
        }
    }
}
