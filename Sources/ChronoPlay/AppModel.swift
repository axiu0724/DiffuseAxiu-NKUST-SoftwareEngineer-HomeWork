import AppKit
import AuthenticationServices
import ChronoPlayCore
import Observation
import SwiftUI

/// 側邊欄選到的項目。
enum SidebarItem: Hashable {
    case artist(Artist.ID)
    case likedSongs
    case playlist(Playlist.ID)
}

/// 藝人頁顯示用的資料：過濾後的時間軸、依年份分段、發行數。建立一次，重繪時直接用。
struct TimelineDisplay {
    struct YearGroup {
        let year: String
        let rows: [(index: Int, entry: DiscographyEntry)]
    }

    private(set) var entries: [DiscographyEntry] = []
    private(set) var groups: [YearGroup] = []
    private(set) var albumCount = 0

    init() {}

    init(_ entries: [DiscographyEntry]) {
        self.entries = entries
        albumCount = Set(entries.map(\.album.id)).count
        var rows: [(index: Int, entry: DiscographyEntry)] = []
        var year: String?
        for (index, entry) in entries.enumerated() {
            let y = entry.release.yearText
            if y != year, let year {
                groups.append(YearGroup(year: year, rows: rows))
                rows = []
            }
            year = y
            rows.append((index, entry))
        }
        if let year { groups.append(YearGroup(year: year, rows: rows)) }
    }
}

/// 整個 app 的狀態：登入、搜尋、藝人作品時間軸、播放清單、裝置，以及連續播放控制器。
@MainActor
@Observable
final class AppModel {
    private enum Keys {
        static let clientID = "spotifyClientID"
        static let windowSize = "playbackWindowSize"
    }

    static let defaultWindowSize = 100
    /// 設定裡可選的 window 大小。3 是測試用：很快就會跨過邊界，可以檢查補佇列是否正常。
    static let windowSizeOptions = [3, 10, 50, 100, 200]

    // MARK: 設定

    private(set) var clientID: String
    var windowSize: Int {
        didSet { UserDefaults.standard.set(windowSize, forKey: Keys.windowSize) }
    }

    // MARK: 登入與服務

    private(set) var isLoggedIn = false
    private(set) var isLoggingIn = false
    private var tokens: TokenManager
    private var client: SpotifyClient
    private(set) var player: PlaybackController
    private let tokenStore: any TokenStore

    // MARK: 搜尋與作品

    var searchText = ""
    private(set) var searchResults: [Artist] = []
    private(set) var isSearching = false
    /// 最後一次完成搜尋的關鍵字，用來判斷「還在等待搜尋」或「真的沒有結果」
    private var lastSearchedQuery = ""

    var hasPendingSearch: Bool {
        isSearching || searchText.trimmingCharacters(in: .whitespaces) != lastSearchedQuery
    }
    var selection: SidebarItem? {
        didSet {
            guard selection != oldValue else { return }
            // 取消上一個選項還沒做完的工作，避免和新選項搶 Spotify 的請求額度。
            selectionTask?.cancel()
            selectionTask = Task { await selectionChanged() }
        }
    }
    @ObservationIgnored private var selectionTask: Task<Void, Never>?
    var selectedArtistID: Artist.ID? {
        if case .artist(let id) = selection { id } else { nil }
    }
    private(set) var selectedArtist: Artist?
    /// 目前藝人的完整時間軸（所有類型），用 enabledKinds 在本機過濾
    private(set) var timeline: [DiscographyEntry] = [] {
        didSet { timelineDisplay = TimelineDisplay(timeline.filter { enabledKinds.contains($0.kind) }) }
    }
    var enabledKinds: Set<ReleaseKind> = Set(ReleaseKind.allCases) {
        didSet { timelineDisplay = TimelineDisplay(timeline.filter { enabledKinds.contains($0.kind) }) }
    }
    /// 藝人頁顯示用的資料。只在 timeline 或 enabledKinds 改變時重算，不在每次重繪時算。
    private(set) var timelineDisplay = TimelineDisplay()
    private(set) var loadingProgress: (done: Int, total: Int)?
    /// 最近看過的藝人時間軸，最多留 `timelineCacheLimit` 位
    private var timelineCache: [Artist.ID: [DiscographyEntry]] = [:]
    /// 時間軸快取的使用順序，最近用過的在最後
    @ObservationIgnored private var timelineCacheOrder: [Artist.ID] = []
    private static let timelineCacheLimit = 10
    private var loadTask: Task<Void, Never>?

    // MARK: 播放清單與已按讚的歌曲

    /// 歌曲存在哪些清單
    private(set) var library = LibraryIndex()
    /// 每個可讀清單的內容（依清單原本的順序）
    private(set) var playlistEntries: [Playlist.ID: [DiscographyEntry]] = [:] {
        didSet { playlistDurationsMs = playlistEntries.mapValues(Self.totalDurationMs) }
    }
    /// 已按讚的歌曲（第一次打開時才讀取，可能有上千首）
    private(set) var likedEntries: [DiscographyEntry]? = nil {
        didSet { likedDurationMs = likedEntries.map(Self.totalDurationMs) ?? 0 }
    }
    /// 清單的總時長（毫秒），清單內容改變時才重算
    private var playlistDurationsMs: [Playlist.ID: Int] = [:]
    private var likedDurationMs = 0
    /// 上次讀到的清單內容，重新整理時 snapshot_id 沒變的清單直接沿用
    @ObservationIgnored private var lastPlaylistContents: LibraryLoader.PlaylistContents?
    /// 正在查詢已按讚狀態的 URI，避免同一批歌重複送出
    @ObservationIgnored private var likedQueriesInFlight: Set<String> = []
    private(set) var isLoadingLiked = false
    /// 讀取清單中的進度；nil 代表沒有在讀取
    private(set) var libraryProgress: (done: Int, total: Int)?
    /// 目前的登入沒有讀取清單的權限（舊版登入），需要重新登入
    private(set) var needsLibraryAuthorization = false
    private var libraryTask: Task<Void, Never>?
    private var likedTask: Task<Void, Never>?

    // MARK: 裝置與錯誤

    private(set) var devices: [Device] = []
    var errorMessage: String?

    init() {
        // 封面用 AsyncImage 載入，它沒有自己的圖片快取，只靠 URLCache.shared，預設容量很小。
        // 要在第一次用到 URLSession.shared（建立 SpotifyClient）之前設定。
        URLCache.shared = URLCache(memoryCapacity: 50 * 1024 * 1024, diskCapacity: 200 * 1024 * 1024)

        let defaults = UserDefaults.standard
        let savedClientID = defaults.string(forKey: Keys.clientID) ?? ""
        let savedWindow = defaults.integer(forKey: Keys.windowSize)
        let store = KeychainTokenStore()
        // Keychain 只讀一次，結果直接交給 TokenManager。
        let savedTokens = store.load()
        let tokens = TokenManager(clientID: savedClientID, store: store, savedTokens: savedTokens)
        let client = SpotifyClient(tokens: tokens)

        self.clientID = savedClientID
        self.windowSize = Self.windowSizeOptions.contains(savedWindow) ? savedWindow : Self.defaultWindowSize
        self.tokenStore = store
        self.tokens = tokens
        self.client = client
        self.player = PlaybackController(api: client)

        observeAppActivation()
        if !savedClientID.isEmpty, savedTokens != nil {
            didLogin()
        }
    }

    /// 讓播放器知道 app 是否在前景，決定輪詢的頻率。
    private func observeAppActivation() {
        let center = NotificationCenter.default
        for (name, isActive) in [(NSApplication.didBecomeActiveNotification, true), (NSApplication.didResignActiveNotification, false)] {
            _ = center.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.player.isAppActive = isActive }
            }
        }
    }

    var visibleTimeline: [DiscographyEntry] { timelineDisplay.entries }

    /// 清單的總時長（毫秒）
    func totalDurationMs(of item: SidebarItem) -> Int {
        switch item {
        case .likedSongs: likedDurationMs
        case .playlist(let id): playlistDurationsMs[id] ?? 0
        case .artist: 0
        }
    }

    private static func totalDurationMs(_ entries: [DiscographyEntry]) -> Int {
        entries.reduce(0) { $0 + $1.track.durationMs }
    }

    /// 目前畫面上的歌曲清單，也是按下播放時要連續播放的那一份
    var currentEntries: [DiscographyEntry] {
        switch selection {
        case .artist: visibleTimeline
        case .likedSongs: likedEntries ?? []
        case .playlist(let id): playlistEntries[id] ?? []
        case nil: []
        }
    }

    func playlist(id: Playlist.ID) -> Playlist? {
        library.playlist(id: id)
    }

    func locations(of entry: DiscographyEntry) -> [SavedLocation] {
        library.locations(of: entry.track.uri)
    }

    var hasClientID: Bool { !clientID.isEmpty }

    // MARK: - 登入

    /// 更換 Client ID 時，舊的 token 不能再用，所以重新建立服務並登出。
    func setClientID(_ newValue: String) {
        let trimmed = newValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed != clientID else { return }
        logout()
        clientID = trimmed
        UserDefaults.standard.set(trimmed, forKey: Keys.clientID)
        // 剛登出，Keychain 裡已經沒有 token，不用再讀一次。
        tokens = TokenManager(clientID: trimmed, store: tokenStore, savedTokens: nil)
        client = SpotifyClient(tokens: tokens)
        player = PlaybackController(api: client)
        player.isAppActive = NSApplication.shared.isActive
    }

    func login(using session: WebAuthenticationSession) async {
        guard hasClientID else {
            errorMessage = SpotifyAuthError.missingClientID.localizedDescription
            return
        }
        isLoggingIn = true
        defer { isLoggingIn = false }

        let pkce = PKCE.generate()
        let state = PKCE.randomState()
        let url = SpotifyAuthConfig(clientID: clientID).authorizeURL(pkce: pkce, state: state)
        do {
            let callback = try await session.authenticate(
                using: url,
                callback: .customScheme(SpotifyAuthConfig.callbackScheme),
                preferredBrowserSession: .shared,
                additionalHeaderFields: [:]
            )
            let code = try SpotifyAuthConfig.code(from: callback, expectedState: state)
            try await tokens.exchange(code: code, pkce: pkce)
            didLogin()
        } catch let error as ASWebAuthenticationSessionError where error.code == .canceledLogin {
            // 使用者關掉登入視窗，不顯示錯誤
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    /// 登入後只在這裡讀一次裝置清單（DeviceMenu 不再自己讀）。
    private func didLogin() {
        isLoggedIn = true
        player.startPolling()
        Task { await refreshDevices() }
        Task { await refreshLibrary() }
    }

    func logout() {
        player.stopPolling()
        player.stopSequence()
        // TokenManager 會清掉 Keychain（並確保進行中的 refresh 不會寫回），這裡不再重複清一次。
        Task { [tokens] in await tokens.logout() }
        isLoggedIn = false
        searchResults = []
        selection = nil
        selectedArtist = nil
        timeline = []
        timelineCache = [:]
        timelineCacheOrder = []
        devices = []
        libraryTask?.cancel()
        likedTask?.cancel()
        library = LibraryIndex()
        lastPlaylistContents = nil
        playlistEntries = [:]
        likedEntries = nil
        isLoadingLiked = false
        libraryProgress = nil
        needsLibraryAuthorization = false
    }

    // MARK: - 搜尋

    func search() async {
        let query = searchText.trimmingCharacters(in: .whitespaces)
        guard isLoggedIn, !query.isEmpty else {
            searchResults = []
            lastSearchedQuery = query
            return
        }
        isSearching = true
        defer { isSearching = false }
        do {
            searchResults = try await client.searchArtists(query)
            lastSearchedQuery = query
        } catch is CancellationError {
        } catch let error as URLError where error.code == .cancelled {
        } catch {
            report(error)
        }
    }

    // MARK: - 選取項目

    private func selectionChanged() async {
        switch selection {
        case .artist, nil:
            await loadSelectedArtist()
        case .likedSongs:
            // 離開還在讀取的藝人：停掉它剩下的上百個曲目請求，不和這個清單搶額度。
            loadTask?.cancel()
            await loadLikedIfNeeded()
        case .playlist(let id):
            loadTask?.cancel()
            await checkLiked(playlistEntries[id] ?? [])
        }
    }

    // MARK: - 作品時間軸

    private func loadSelectedArtist() async {
        loadTask?.cancel()
        guard let id = selectedArtistID else {
            selectedArtist = nil
            timeline = []
            return
        }
        selectedArtist = searchResults.first { $0.id == id } ?? selectedArtist
        if let cached = timelineCache[id] {
            touchTimelineCache(id)
            timeline = cached
            loadingProgress = nil
            await checkLiked(cached)
            return
        }

        timeline = []
        loadingProgress = (0, 0)
        let task = Task { [client] in
            do {
                let entries = try await DiscographyBuilder.build(
                    artistID: id,
                    kinds: Set(ReleaseKind.allCases),
                    api: client,
                    progress: { done, total in
                        Task { @MainActor in
                            guard self.selectedArtistID == id else { return }
                            self.loadingProgress = (done, total)
                        }
                    }
                )
                try Task.checkCancellation()
                timelineCache[id] = entries
                touchTimelineCache(id)
                if selectedArtistID == id {
                    timeline = entries
                    loadingProgress = nil
                    await checkLiked(entries)
                }
            } catch is CancellationError {
            } catch {
                // 被取消（換了藝人或重新讀取）時，進度由新的讀取負責，不要清掉。
                guard !Self.isCancellation(error) else { return }
                if selectedArtistID == id { loadingProgress = nil }
                report(error)
            }
        }
        loadTask = task
        await task.value
    }

    /// 把藝人標成最近用過，超過上限時丟掉最久沒看的。
    private func touchTimelineCache(_ id: Artist.ID) {
        timelineCacheOrder.removeAll { $0 == id }
        timelineCacheOrder.append(id)
        while timelineCacheOrder.count > Self.timelineCacheLimit {
            timelineCache[timelineCacheOrder.removeFirst()] = nil
        }
    }

    func reloadSelectedArtist() async {
        guard let id = selectedArtistID else { return }
        timelineCache[id] = nil
        await loadSelectedArtist()
    }

    // MARK: - 播放清單與已按讚的歌曲

    /// 重新讀取所有清單。已按讚的狀態也一併清掉重查，因為可能在官方 app 改過。
    func refreshLibrary() async {
        guard isLoggedIn else { return }
        needsLibraryAuthorization = !SpotifyAuthConfig.covers(await tokens.grantedScopes)
        guard !needsLibraryAuthorization else { return }

        libraryTask?.cancel()
        likedTask?.cancel()
        library = LibraryIndex()
        likedEntries = nil
        isLoadingLiked = false
        libraryProgress = (0, 0)

        let task = Task { [client, previous = lastPlaylistContents] in
            do {
                let contents = try await LibraryLoader.loadPlaylists(api: client, previous: previous, progress: { done, total in
                    Task { @MainActor in
                        if self.libraryProgress != nil { self.libraryProgress = (done, total) }
                    }
                })
                try Task.checkCancellation()
                // 轉換和索引都在 LibraryLoader 裡（不在主執行緒）做好了，這裡只指派結果。
                library.setPlaylists(from: contents.index)
                playlistEntries = contents.entries
                lastPlaylistContents = contents
                libraryProgress = nil
            } catch is CancellationError {
            } catch {
                libraryProgress = nil
                report(error)
            }
        }
        libraryTask = task
        await task.value
        if !task.isCancelled { await refreshSavedStatusOnScreen() }
    }

    /// 重新查目前畫面上歌曲的已按讚狀態（打開的是已按讚的歌曲時，改成重新讀取它）。
    private func refreshSavedStatusOnScreen() async {
        switch selection {
        case .artist: await checkLiked(timeline)
        case .likedSongs: await loadLikedIfNeeded()
        case .playlist(let id): await checkLiked(playlistEntries[id] ?? [])
        case nil: break
        }
    }

    func loadLikedIfNeeded() async {
        guard isLoggedIn, !needsLibraryAuthorization, likedEntries == nil, !isLoadingLiked else { return }
        isLoadingLiked = true
        let task = Task { [client] in
            do {
                // 轉換在 LibraryLoader 裡（不在主執行緒）做好，這裡只指派結果。
                let liked = try await LibraryLoader.loadLiked(api: client)
                try Task.checkCancellation()
                likedEntries = liked.entries
                library.replaceLiked(with: liked.uris)
            } catch is CancellationError {
            } catch {
                report(error)
            }
            isLoadingLiked = false
        }
        likedTask = task
        await task.value
    }

    /// 查詢還不知道是否已按讚的歌曲。
    private func checkLiked(_ entries: [DiscographyEntry]) async {
        guard isLoggedIn, !needsLibraryAuthorization else { return }
        // 已經在查的 URI 不重複送（例如快速切回同一個清單）。
        let unknown = entries.map(\.track.uri).filter { !library.isLikedKnown($0) && !likedQueriesInFlight.contains($0) }
        guard !unknown.isEmpty else { return }
        likedQueriesInFlight.formUnion(unknown)
        defer { likedQueriesInFlight.subtract(unknown) }
        do {
            let status = try await LibraryLoader.likedStatus(of: unknown, api: client)
            library.setLiked(status)
        } catch is CancellationError {
        } catch {
            report(error)
        }
    }

    // MARK: - 播放

    func play(from entry: DiscographyEntry? = nil) async {
        let list = currentEntries
        guard !list.isEmpty else { return }
        let index = entry.flatMap { e in list.firstIndex { $0.id == e.id } } ?? 0
        await player.start(entries: list, at: index, windowSize: windowSize)
    }

    // MARK: - 裝置

    func refreshDevices() async {
        guard isLoggedIn else { return }
        do {
            devices = try await client.devices()
            if player.deviceID == nil || !devices.contains(where: { $0.id == player.deviceID }) {
                player.deviceID = (devices.first { $0.isActive } ?? devices.first)?.id
            }
        } catch {
            report(error)
        }
    }

    func select(device: Device) async {
        guard let id = device.id else { return }
        player.deviceID = id
        do {
            try await client.transferPlayback(to: id, play: player.state?.isPlaying ?? false)
        } catch {
            report(error)
        }
    }

    func openSpotifyApp() {
        if let url = URL(string: "spotify:") {
            NSWorkspace.shared.open(url)
        }
        Task {
            try? await Task.sleep(for: .seconds(4))
            await refreshDevices()
        }
    }

    // MARK: - 錯誤

    /// 工作被取消時，URLSession 丟的是 URLError(.cancelled)，不是 CancellationError。
    private static func isCancellation(_ error: any Error) -> Bool {
        error is CancellationError || (error as? URLError)?.code == .cancelled
    }

    private func report(_ error: any Error) {
        // 切換選項時取消的請求不是錯誤，不顯示。
        guard !Self.isCancellation(error) else { return }
        if case SpotifyAuthError.notLoggedIn = error {
            isLoggedIn = false
            player.stopPolling()
        } else if case SpotifyAuthError.tokenRequestFailed = error {
            isLoggedIn = false
            player.stopPolling()
        } else if let error = error as? SpotifyAPIError, error.status == 403, error.message.lowercased().contains("scope") {
            // 登入時沒有授權讀取清單：請使用者重新登入，不跳錯誤視窗
            needsLibraryAuthorization = true
            return
        }
        errorMessage = error.localizedDescription
    }
}
