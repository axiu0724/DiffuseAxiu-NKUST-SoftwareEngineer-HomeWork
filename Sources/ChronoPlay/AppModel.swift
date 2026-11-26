import AppKit
import AuthenticationServices
import ChronoPlayCore
import Observation
import SwiftUI

/// 整個 app 的狀態：登入、搜尋、藝人作品時間軸、裝置，以及連續播放控制器。
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
    var selectedArtistID: Artist.ID? {
        didSet { if selectedArtistID != oldValue { Task { await loadSelectedArtist() } } }
    }
    private(set) var selectedArtist: Artist?
    /// 目前藝人的完整時間軸（所有類型），用 enabledKinds 在本機過濾
    private(set) var timeline: [DiscographyEntry] = []
    var enabledKinds: Set<ReleaseKind> = Set(ReleaseKind.allCases)
    private(set) var loadingProgress: (done: Int, total: Int)?
    private var timelineCache: [Artist.ID: [DiscographyEntry]] = [:]
    private var loadTask: Task<Void, Never>?

    // MARK: 裝置與錯誤

    private(set) var devices: [Device] = []
    var errorMessage: String?

    init() {
        let defaults = UserDefaults.standard
        let savedClientID = defaults.string(forKey: Keys.clientID) ?? ""
        let savedWindow = defaults.integer(forKey: Keys.windowSize)
        let store = KeychainTokenStore()
        let tokens = TokenManager(clientID: savedClientID, store: store)
        let client = SpotifyClient(tokens: tokens)

        self.clientID = savedClientID
        self.windowSize = Self.windowSizeOptions.contains(savedWindow) ? savedWindow : Self.defaultWindowSize
        self.tokenStore = store
        self.tokens = tokens
        self.client = client
        self.player = PlaybackController(api: client)

        if !savedClientID.isEmpty, store.load() != nil {
            didLogin()
        }
    }

    var visibleTimeline: [DiscographyEntry] {
        timeline.filter { enabledKinds.contains($0.kind) }
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
        tokens = TokenManager(clientID: trimmed, store: tokenStore)
        client = SpotifyClient(tokens: tokens)
        player = PlaybackController(api: client)
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

    private func didLogin() {
        isLoggedIn = true
        player.startPolling()
        Task { await refreshDevices() }
    }

    func logout() {
        player.stopPolling()
        player.stopSequence()
        Task { [tokens] in await tokens.logout() }
        tokenStore.clear()
        isLoggedIn = false
        searchResults = []
        selectedArtistID = nil
        selectedArtist = nil
        timeline = []
        timelineCache = [:]
        devices = []
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
            timeline = cached
            loadingProgress = nil
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
                if selectedArtistID == id {
                    timeline = entries
                    loadingProgress = nil
                }
            } catch is CancellationError {
            } catch {
                if selectedArtistID == id { loadingProgress = nil }
                report(error)
            }
        }
        loadTask = task
        await task.value
    }

    func reloadSelectedArtist() async {
        guard let id = selectedArtistID else { return }
        timelineCache[id] = nil
        await loadSelectedArtist()
    }

    // MARK: - 播放

    func play(from entry: DiscographyEntry? = nil) async {
        let list = visibleTimeline
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

    private func report(_ error: any Error) {
        if case SpotifyAuthError.notLoggedIn = error {
            isLoggedIn = false
            player.stopPolling()
        } else if case SpotifyAuthError.tokenRequestFailed = error {
            isLoggedIn = false
            player.stopPolling()
        }
        errorMessage = error.localizedDescription
    }
}
