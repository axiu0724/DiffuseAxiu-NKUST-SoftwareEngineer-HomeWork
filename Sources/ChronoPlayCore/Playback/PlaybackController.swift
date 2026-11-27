import Foundation
import Observation

/// 播放器需要的 API。SpotifyClient 會實作它，測試時可以換成假的播放器。
public protocol PlayerAPI: Sendable {
    func play(uris: [String], deviceID: String?) async throws
    func resume(deviceID: String?) async throws
    func pause(deviceID: String?) async throws
    func addToQueue(uri: String, deviceID: String?) async throws
    func skipToNext(deviceID: String?) async throws
    func skipToPrevious(deviceID: String?) async throws
    func playbackState() async throws -> PlaybackState?
}

extension SpotifyClient: PlayerAPI {}

/// 執行 SequencePlan：定時輪詢播放狀態、把決策轉成 API 呼叫，並提供介面需要的狀態。
@MainActor
@Observable
public final class PlaybackController {
    public private(set) var plan: SequencePlan?
    /// 正在連續播放的那份清單
    public private(set) var entries: [DiscographyEntry] = []
    public private(set) var state: PlaybackState?
    /// 上次取得狀態的時間，用來在兩次輪詢之間推算進度條
    public private(set) var stateFetchedAt: Date?
    public var deviceID: String?
    public var lastError: String?
    /// app 是否在前景。不在前景、也沒有在連續播放時，輪詢會放慢。回到前景時立刻查一次。
    public var isAppActive = true {
        didSet { if isAppActive, !oldValue { pollSleepTask?.cancel() } }
    }

    private let api: any PlayerAPI
    /// lastError 是不是輪詢造成的（例如暫時斷線）。是的話，下次輪詢成功就自動清掉。
    private var errorIsFromPolling = false
    private var pollTask: Task<Void, Never>?
    /// 兩次輪詢之間的等待。取消它只會提早結束等待，不會中斷進行中的請求。
    private var pollSleepTask: Task<Void, Never>?
    /// 輪詢正在等待時，預計下次查詢的時間
    @ObservationIgnored private(set) var nextPollAt: ContinuousClock.Instant?
    /// 別處剛查過狀態、需要更密的輪詢時，輪詢被叫醒後改用這個間隔等待，不重複查詢
    @ObservationIgnored private var rescheduledDelay: Duration?

    public init(api: any PlayerAPI) {
        self.api = api
    }

    public var currentEntry: DiscographyEntry? {
        guard let plan, plan.status != .detached, entries.indices.contains(plan.currentIndex) else { return nil }
        return entries[plan.currentIndex]
    }

    // MARK: - 連續播放

    public func start(entries: [DiscographyEntry], at index: Int, windowSize: Int) async {
        guard entries.indices.contains(index) else { return }
        self.entries = entries
        let (plan, actions) = SequencePlan.start(uris: entries.map(\.track.uri), at: index, windowSize: windowSize)
        self.plan = plan
        lastError = nil
        guard await perform(actions) else {
            // 例如沒有可用裝置或不是 Premium：放棄這次計畫，錯誤訊息留在 lastError
            self.plan = nil
            return
        }
        try? await Task.sleep(for: .milliseconds(600))
        await refresh()
    }

    /// 離開連續播放後，從原本播到的那首繼續。
    public func resumeSequence(windowSize: Int) async {
        guard let plan else { return }
        let index = plan.status == .finished ? 0 : plan.currentIndex
        await start(entries: entries, at: index, windowSize: windowSize)
    }

    public func stopSequence() {
        plan = nil
        entries = []
    }

    // MARK: - 播放控制

    public func togglePlayPause() async {
        let playing = state?.isPlaying ?? false
        await run { [api, deviceID] in
            if playing { try await api.pause(deviceID: deviceID) } else { try await api.resume(deviceID: deviceID) }
        }
        await refreshSoon()
    }

    public func next() async {
        await run { [api, deviceID] in try await api.skipToNext(deviceID: deviceID) }
        await refreshSoon()
    }

    public func previous() async {
        await run { [api, deviceID] in try await api.skipToPrevious(deviceID: deviceID) }
        await refreshSoon()
    }

    // MARK: - 輪詢

    public func startPolling() {
        guard pollTask == nil else { return }
        pollTask = Task { [weak self] in
            guard var delay = await self?.refresh() else { return }
            while !Task.isCancelled {
                guard let self else { return }
                await self.sleepUntilNextPoll(delay)
                guard !Task.isCancelled else { return }
                if let rescheduled = self.takeRescheduledDelay() {
                    delay = rescheduled
                } else {
                    delay = await self.refresh()
                }
            }
        }
    }

    public func stopPolling() {
        pollTask?.cancel()
        pollTask = nil
        pollSleepTask?.cancel()
    }

    private func sleepUntilNextPoll(_ delay: Duration) async {
        nextPollAt = .now + delay
        let sleep = Task { _ = try? await Task.sleep(for: delay) }
        pollSleepTask = sleep
        await sleep.value
        nextPollAt = nil
    }

    private func takeRescheduledDelay() -> Duration? {
        defer { rescheduledDelay = nil }
        return rescheduledDelay
    }

    /// 取得一次播放狀態並推進計畫。回傳建議的下次輪詢間隔。
    @discardableResult
    public func refresh() async -> Duration {
        let fetched: PlaybackState?
        do {
            fetched = try await api.playbackState()
        } catch {
            if lastError == nil || errorIsFromPolling {
                lastError = error.localizedDescription
                errorIsFromPolling = true
            }
            return .seconds(5)
        }
        if errorIsFromPolling {
            lastError = nil
            errorIsFromPolling = false
        }
        state = fetched
        stateFetchedAt = .now
        if deviceID == nil, let id = fetched?.device?.id { deviceID = id }

        if var plan {
            let actions = plan.observe(currentURI: fetched?.item?.uri)
            self.plan = plan
            await perform(actions)
        }
        let delay = nextPollDelay()
        // 開始連續播放、按播放鍵這類手動查詢，可能讓間隔變短（例如背景閒置的 30 秒 → 3 秒）。
        // 輪詢還在等較久的時間的話，叫醒它改用新的間隔；這次已經查過，它不會再多查一次。
        if let nextPollAt, nextPollAt > .now + delay {
            rescheduledDelay = delay
            pollSleepTask?.cancel()
        }
        return delay
    }

    private func refreshSoon() async {
        try? await Task.sleep(for: .milliseconds(500))
        await refresh()
    }

    /// 播放中每 3 秒輪詢一次；歌快結束時提早一點查，讓補佇列和「播完暫停」更準時。
    /// 連續播放中（或剛送出 play、還在等 Spotify 開始播）不管前景背景都維持這個頻率；
    /// 其他情況在背景放慢到 30 秒，前景暫停或沒在播時 10 秒。
    private func nextPollDelay() -> Duration {
        let isPlaying = state?.isPlaying == true
        let needsPrecision = plan?.status == .playing && (isPlaying || plan?.hasConfirmedStart == false)
        if !needsPrecision {
            if !isAppActive { return .seconds(30) }
            if !isPlaying { return .seconds(10) }
        }
        guard let state, isPlaying else { return .seconds(3) }
        if let duration = state.item?.durationMs, let progress = state.progressMs {
            let remaining = Double(duration - progress) / 1000
            if remaining < 3.5 { return .seconds(max(remaining + 0.4, 0.5)) }
        }
        return .seconds(3)
    }

    @discardableResult
    private func perform(_ actions: [SequencePlan.Action]) async -> Bool {
        var ok = true
        for action in actions {
            ok = await run { [api, deviceID] in
                switch action {
                case .play(let uris): try await api.play(uris: uris, deviceID: deviceID)
                case .enqueue(let uri): try await api.addToQueue(uri: uri, deviceID: deviceID)
                case .pause: try await api.pause(deviceID: deviceID)
                }
            } && ok
        }
        return ok
    }

    @discardableResult
    private func run(_ body: @Sendable () async throws -> Void) async -> Bool {
        do {
            try await body()
            return true
        } catch {
            lastError = error.localizedDescription
            errorIsFromPolling = false
            return false
        }
    }
}
