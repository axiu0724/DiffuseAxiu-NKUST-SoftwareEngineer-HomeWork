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

    private let api: any PlayerAPI
    /// lastError 是不是輪詢造成的（例如暫時斷線）。是的話，下次輪詢成功就自動清掉。
    private var errorIsFromPolling = false
    private var pollTask: Task<Void, Never>?

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
            while !Task.isCancelled {
                guard let self else { return }
                let delay = await self.refresh()
                try? await Task.sleep(for: delay)
            }
        }
    }

    public func stopPolling() {
        pollTask?.cancel()
        pollTask = nil
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
        return nextPollDelay()
    }

    private func refreshSoon() async {
        try? await Task.sleep(for: .milliseconds(500))
        await refresh()
    }

    /// 平常每 3 秒輪詢一次；歌快結束時提早一點查，讓補佇列和「播完暫停」更準時。
    private func nextPollDelay() -> Duration {
        guard let state, state.isPlaying else { return .seconds(plan == nil ? 5 : 3) }
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
