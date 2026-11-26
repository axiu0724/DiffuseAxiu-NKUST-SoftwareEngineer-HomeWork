import Foundation

/// 讀取使用者收藏需要的 API。SpotifyClient 會實作它，測試時可以換成假資料。
public protocol LibraryAPI: Sendable {
    func currentUserID() async throws -> String
    /// 必須回傳所有分頁。
    func myPlaylists() async throws -> [Playlist]
    /// 必須回傳所有分頁。不是自己建立或協作的清單會丟出 HTTP 403。
    func playlistItems(playlistID: String) async throws -> [LibraryItem]
    /// 已按讚的歌曲，必須回傳所有分頁。
    func likedItems() async throws -> [LibraryItem]
    /// 每個 URI 是否在「已按讚的歌曲」裡，順序與輸入相同。一次最多 `LibraryLoader.containsBatchSize` 個。
    func libraryContains(uris: [String]) async throws -> [Bool]
}

/// 歌曲被收藏在哪裡。
public enum SavedLocation: Sendable, Hashable, Identifiable {
    case liked
    case playlist(Playlist)

    public var id: String {
        switch self {
        case .liked: "liked"
        case .playlist(let playlist): playlist.id
        }
    }
}

/// 把清單內容轉成時間軸 entry，讓清單也能用同一套播放引擎與曲目列表。
public enum PlaylistEntries {
    /// - 本機檔案、不能播的歌曲、下架或 podcast 單集會略過。
    /// - 同一首歌在清單裡出現多次時，每一次都保留，並給不同的 id。
    public static func make(_ items: [LibraryItem]) -> [DiscographyEntry] {
        var counts: [String: Int] = [:]
        return items.compactMap { item in
            guard let full = item.track, full.track.isLocal != true, full.track.isPlayable != false else { return nil }
            let kind: ReleaseKind = full.album.albumType == "single" ? .single : .album
            let base = DiscographyEntry(track: full.track, album: full.album, kind: kind)
            let occurrence = counts[base.id, default: 0]
            counts[base.id] = occurrence + 1
            return DiscographyEntry(track: full.track, album: full.album, kind: kind, occurrence: occurrence)
        }
    }
}

/// 「這首歌存在哪些清單」的索引。
///
/// 比對方式和官方 app 一樣用歌曲 URI：同一首歌的原版和豪華版是不同的 URI，各自判斷。
public struct LibraryIndex: Sendable {
    /// 依 `GET /me/playlists` 的順序
    public private(set) var playlists: [Playlist] = []
    /// 讀不到內容的清單（別人建立、你只是追蹤）
    public private(set) var unreadable: Set<Playlist.ID> = []
    /// 已讀取內容的清單：URI → 所在清單的 id（依清單順序）
    private var membership: [String: [Playlist.ID]] = [:]
    /// 已查過的「已按讚」狀態
    private var liked: [String: Bool] = [:]

    public init() {}

    public mutating func setPlaylists(_ playlists: [Playlist], unreadable: Set<Playlist.ID>, contents: [Playlist.ID: [String]]) {
        self.playlists = playlists
        self.unreadable = unreadable
        membership = [:]
        for playlist in playlists {
            for uri in Set(contents[playlist.id] ?? []) {
                membership[uri, default: []].append(playlist.id)
            }
        }
    }

    public mutating func setLiked(_ status: [String: Bool]) {
        liked.merge(status) { $1 }
    }

    /// 知道完整的已按讚清單時，用它覆蓋所有已查過的狀態。
    public mutating func replaceLiked(with uris: Set<String>) {
        for key in liked.keys { liked[key] = false }
        for uri in uris { liked[uri] = true }
    }

    public func isLikedKnown(_ uri: String) -> Bool { liked[uri] != nil }

    /// 歌曲所在的位置：已按讚的歌曲排第一，其餘依清單順序。沒有收藏時回傳空陣列。
    public func locations(of uri: String) -> [SavedLocation] {
        var result: [SavedLocation] = liked[uri] == true ? [.liked] : []
        let ids = Set(membership[uri] ?? [])
        result += playlists.filter { ids.contains($0.id) }.map(SavedLocation.playlist)
        return result
    }
}

public enum LibraryLoader {
    /// `GET /me/library/contains` 一次最多 40 個 URI。
    public static let containsBatchSize = 40

    public struct PlaylistContents: Sendable {
        public var playlists: [Playlist]
        public var items: [Playlist.ID: [LibraryItem]]
        public var unreadable: Set<Playlist.ID>

        /// 給 `LibraryIndex.setPlaylists` 用的 URI 清單
        public var uris: [Playlist.ID: [String]] {
            items.mapValues { $0.compactMap { $0.track?.track.uri } }
        }
    }

    /// 抓出所有清單，並讀取每個可讀清單的內容。
    /// 讀不到的清單（不是自己的，或 Spotify 回 403）記在 `unreadable`，不會讓整個流程失敗。
    public static func loadPlaylists(
        api: some LibraryAPI,
        maxConcurrentRequests: Int = 4,
        progress: (@Sendable (Int, Int) -> Void)? = nil
    ) async throws -> PlaylistContents {
        async let userID = api.currentUserID()
        let playlists = try await api.myPlaylists()
        let me = try await userID

        var unreadable = Set(playlists.filter { !$0.isReadable(byUserID: me) }.map(\.id))
        let readable = playlists.filter { !unreadable.contains($0.id) }
        var items: [Playlist.ID: [LibraryItem]] = [:]
        progress?(0, readable.count)

        try await withThrowingTaskGroup(of: (Playlist.ID, [LibraryItem]?).self) { group in
            var next = 0
            var finished = 0
            func addTask() {
                let id = readable[next].id
                next += 1
                group.addTask {
                    do {
                        return (id, try await api.playlistItems(playlistID: id))
                    } catch let error as SpotifyAPIError where error.status == 403 || error.status == 404 {
                        return (id, nil)
                    }
                }
            }
            for _ in 0..<min(maxConcurrentRequests, readable.count) { addTask() }
            while let (id, result) = try await group.next() {
                if let result { items[id] = result } else { unreadable.insert(id) }
                finished += 1
                progress?(finished, readable.count)
                if next < readable.count { addTask() }
            }
        }
        return PlaylistContents(playlists: playlists, items: items, unreadable: unreadable)
    }

    /// 查一批歌曲是否已按讚。重複的 URI 只查一次，並分批送出。
    public static func likedStatus(
        of uris: [String],
        api: some LibraryAPI,
        maxConcurrentRequests: Int = 4
    ) async throws -> [String: Bool] {
        var seen = Set<String>()
        let unique = uris.filter { seen.insert($0).inserted }
        let batches = stride(from: 0, to: unique.count, by: containsBatchSize).map {
            Array(unique[$0..<min($0 + containsBatchSize, unique.count)])
        }

        var result: [String: Bool] = [:]
        try await withThrowingTaskGroup(of: [String: Bool].self) { group in
            var next = 0
            func addTask() {
                let batch = batches[next]
                next += 1
                group.addTask {
                    let flags = try await api.libraryContains(uris: batch)
                    guard flags.count == batch.count else { throw URLError(.badServerResponse) }
                    return Dictionary(uniqueKeysWithValues: zip(batch, flags))
                }
            }
            for _ in 0..<min(maxConcurrentRequests, batches.count) { addTask() }
            while let partial = try await group.next() {
                result.merge(partial) { $1 }
                if next < batches.count { addTask() }
            }
        }
        return result
    }
}
