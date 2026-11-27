@testable import ChronoPlayCore
import Foundation
import Testing

private let decoder: JSONDecoder = {
    let decoder = JSONDecoder()
    decoder.keyDecodingStrategy = .convertFromSnakeCase
    return decoder
}()

private func trackJSON(_ id: String, type: String = "track", local: Bool = false) -> String {
    """
    {"id":"\(id)","name":"\(id)","uri":"spotify:track:\(id)","duration_ms":200000,"disc_number":1,"track_number":1,
     "artists":[{"id":"a","name":"A"}],"is_local":\(local),"type":"\(type)",
     "album":{"id":"al-\(id)","uri":"spotify:album:al-\(id)","name":"專輯","album_type":"single","release_date":"2020-01-02","release_date_precision":"day","artists":[]}}
    """
}

@Suite("播放清單資料解析")
struct LibraryDecodingTests {
    @Test("新版的 item 與舊版的 track 都能解析，podcast 單集與下架歌曲變成 nil")
    func decodeItems() throws {
        let json = """
        [{"added_at":"2026-01-01T00:00:00Z","item":\(trackJSON("new"))},
         {"added_at":null,"track":\(trackJSON("old"))},
         {"item":\(trackJSON("ep", type: "episode"))},
         {"item":null}]
        """
        let items = try decoder.decode([LibraryItem].self, from: Data(json.utf8))
        #expect(items.map { $0.track?.track.id } == ["new", "old", nil, nil])
        #expect(items[0].track?.album.albumType == "single")
    }

    @Test("清單歌曲數讀 items.total，舊版的 tracks.total 也接受")
    func playlistCount() throws {
        let json = """
        [{"id":"p1","name":"新","uri":"spotify:playlist:p1","owner":{"id":"me"},"collaborative":false,"items":{"total":12}},
         {"id":"p2","name":"舊","uri":"spotify:playlist:p2","owner":{"id":"you","display_name":"別人"},"tracks":{"total":3}}]
        """
        let playlists = try decoder.decode([Playlist].self, from: Data(json.utf8))
        #expect(playlists.map(\.trackCount) == [12, 3])
        #expect(playlists[0].isReadable(byUserID: "me"))
        #expect(!playlists[1].isReadable(byUserID: "me"))
        #expect(playlists[1].owner.displayName == "別人")
    }

    @Test("舊版存下來的 token 沒有 scope 也能讀，並視為權限不足")
    func legacyTokens() throws {
        let json = #"{"accessToken":"a","refreshToken":"r","expiresAt":0}"#
        let tokens = try JSONDecoder().decode(Tokens.self, from: Data(json.utf8))
        #expect(tokens.grantedScopes == nil)
        #expect(!SpotifyAuthConfig.covers(tokens.grantedScopes))
        #expect(SpotifyAuthConfig.covers(Set(SpotifyAuthConfig.scopes + ["extra"])))
    }
}

@Suite("播放清單轉成曲目")
struct PlaylistEntriesTests {
    private func item(_ id: String, local: Bool = false, playable: Bool? = nil) -> LibraryItem {
        let album = Fixture.album("al-\(id)", type: id.hasPrefix("s") ? "single" : "album", date: "2020-01-01")
        let track = Track(id: id, name: id, trackNumber: 1, isPlayable: playable, isLocal: local)
        return LibraryItem(track: TrackWithAlbum(track: track, album: album))
    }

    @Test("保留清單順序，同一首歌出現多次時 id 不重複")
    func duplicates() {
        let entries = PlaylistEntries.make([item("b"), item("a"), item("b")])
        #expect(entries.map(\.track.id) == ["b", "a", "b"])
        #expect(Set(entries.map(\.id)).count == 3)
        #expect(entries.map(\.occurrence) == [0, 0, 1])
    }

    @Test("略過本機檔案、不能播放與無法解析的項目，並依專輯類型分類")
    func filtering() {
        let entries = PlaylistEntries.make([
            item("local", local: true), item("blocked", playable: false),
            LibraryItem(track: nil), item("s1"), item("a1"),
        ])
        #expect(entries.map(\.track.id) == ["s1", "a1"])
        #expect(entries.map(\.kind) == [.single, .album])
    }
}

@Suite("收藏索引")
struct LibraryIndexTests {
    let me = PlaylistOwner(id: "me")

    @Test("已按讚排第一，其餘依清單順序；沒收藏回傳空陣列")
    func locations() {
        let first = Playlist(id: "p1", name: "一", owner: me)
        let second = Playlist(id: "p2", name: "二", owner: me)
        var index = LibraryIndex()
        index.setPlaylists([first, second], unreadable: [], contents: ["p2": ["u1", "u1"], "p1": ["u1", "u2"]])
        index.setLiked(["u1": true, "u3": false])

        #expect(index.locations(of: "u1") == [.liked, .playlist(first), .playlist(second)])
        #expect(index.locations(of: "u2") == [.playlist(first)])
        #expect(index.locations(of: "u3").isEmpty)
        #expect(index.isLikedKnown("u3"))
        #expect(!index.isLikedKnown("u2"))
    }

    @Test("讀到完整的已按讚清單時，覆蓋舊的查詢結果")
    func replaceLiked() {
        var index = LibraryIndex()
        index.setLiked(["u1": true, "u2": false])
        index.replaceLiked(with: ["u2", "u3"])
        #expect(index.locations(of: "u1").isEmpty)
        #expect(index.locations(of: "u2") == [.liked])
        #expect(index.locations(of: "u3") == [.liked])
    }
}

/// 假的收藏 API：記錄 contains 收到的每一批 URI。
actor FakeLibrary: LibraryAPI {
    var userID = "me"
    var playlists: [Playlist] = []
    var items: [String: [LibraryItem]] = [:]
    /// 讀取時會回 403 的清單
    var forbidden: Set<String> = []
    var liked: Set<String> = []
    private(set) var containsBatches: [[String]] = []
    private(set) var readPlaylists: [String] = []

    init(playlists: [Playlist] = [], items: [String: [LibraryItem]] = [:], forbidden: Set<String> = [], liked: Set<String> = []) {
        self.playlists = playlists
        self.items = items
        self.forbidden = forbidden
        self.liked = liked
    }

    func setPlaylists(_ playlists: [Playlist]) { self.playlists = playlists }

    func currentUserID() async throws -> String { userID }
    func myPlaylists() async throws -> [Playlist] { playlists }
    func playlistItems(playlistID: String) async throws -> [LibraryItem] {
        readPlaylists.append(playlistID)
        if forbidden.contains(playlistID) {
            throw SpotifyAPIError(status: 403, message: "Forbidden", reason: nil)
        }
        return items[playlistID] ?? []
    }
    func likedItems() async throws -> [LibraryItem] { [] }
    func libraryContains(uris: [String]) async throws -> [Bool] {
        containsBatches.append(uris)
        return uris.map(liked.contains)
    }
}

@Suite("讀取收藏")
struct LibraryLoaderTests {
    private func item(_ id: String) -> LibraryItem {
        LibraryItem(track: TrackWithAlbum(track: Fixture.track(id, number: 1), album: Fixture.album("al", date: "2020")))
    }

    @Test("只讀自己建立或協作的清單；回 403 的清單記為讀不到，不會整個失敗")
    func readableOnly() async throws {
        let own = Playlist(id: "own", name: "自己的", owner: PlaylistOwner(id: "me"))
        let collab = Playlist(id: "collab", name: "協作", owner: PlaylistOwner(id: "friend"), collaborative: true)
        let followed = Playlist(id: "followed", name: "追蹤", owner: PlaylistOwner(id: "label"))
        let api = FakeLibrary(
            playlists: [own, collab, followed],
            items: ["own": [item("t1")], "collab": [item("t2")]],
            forbidden: ["collab"]
        )

        let contents = try await LibraryLoader.loadPlaylists(api: api)
        #expect(Set(await api.readPlaylists) == ["own", "collab"])
        #expect(contents.unreadable == ["collab", "followed"])
        #expect(contents.uris == ["own": ["spotify:track:t1"]])
        #expect(contents.playlists.map(\.id) == ["own", "collab", "followed"])
    }

    @Test("snapshot_id 沒變的清單沿用上次的內容，只重抓改過的清單")
    func reusesUnchangedPlaylists() async throws {
        let me = PlaylistOwner(id: "me")
        let same = Playlist(id: "same", name: "沒變", owner: me, snapshotID: "s1")
        let api = FakeLibrary(
            playlists: [same, Playlist(id: "changed", name: "改過", owner: me, snapshotID: "c1")],
            items: ["same": [item("t1")], "changed": [item("t2")]]
        )
        let first = try await LibraryLoader.loadPlaylists(api: api)

        await api.setPlaylists([same, Playlist(id: "changed", name: "改過", owner: me, snapshotID: "c2")])
        let second = try await LibraryLoader.loadPlaylists(api: api, previous: first)

        let reads = await api.readPlaylists
        #expect(reads.count == 3)
        #expect(reads.last == "changed")
        #expect(second.uris == first.uris)
        #expect(second.entries["same"] == first.entries["same"])
        #expect(second.index.locations(of: "spotify:track:t1") == [.playlist(same)])
    }

    @Test("已按讚狀態去除重複後，每 40 個一批查詢")
    func likedBatches() async throws {
        let uris = (0..<85).map { "spotify:track:\($0)" }
        let api = FakeLibrary(liked: ["spotify:track:3", "spotify:track:84"])

        let status = try await LibraryLoader.likedStatus(of: uris + uris.prefix(10), api: api)
        let batches = await api.containsBatches
        #expect(batches.map(\.count).sorted() == [5, 40, 40])
        #expect(Set(batches.flatMap { $0 }).count == 85)
        #expect(status.count == 85)
        #expect(status.filter(\.value).keys.sorted() == ["spotify:track:3", "spotify:track:84"])
    }
}
