import Foundation

// 使用者自己的播放清單與「已按讚的歌曲」。
// 2026 年 2 月起：播放清單的 `tracks` 改名為 `items`，清單裡每一項的歌曲也從 `track` 改放在 `item`。
// 這裡兩種寫法都接受，避免 Spotify 還在過渡期時解析失敗。

public struct PlaylistOwner: Codable, Sendable, Hashable {
    public let id: String
    public let displayName: String?

    public init(id: String, displayName: String? = nil) {
        self.id = id
        self.displayName = displayName
    }
}

public struct Playlist: Decodable, Sendable, Hashable, Identifiable {
    private struct ItemCount: Decodable, Sendable, Hashable { let total: Int? }

    public let id: String
    public let name: String
    public let uri: String
    public let images: [SpotifyImage]?
    public let owner: PlaylistOwner
    public let collaborative: Bool?
    /// 清單內容每次改變都會換一個新值；相同就代表內容沒變，可以沿用上次讀到的歌曲。
    public let snapshotID: String?
    private let itemCount: ItemCount?
    private let legacyTrackCount: ItemCount?

    private enum CodingKeys: String, CodingKey {
        case id, name, uri, images, owner, collaborative
        // convertFromSnakeCase 會先把 snapshot_id 轉成 snapshotId
        case snapshotID = "snapshotId"
        case itemCount = "items"
        case legacyTrackCount = "tracks"
    }

    public init(
        id: String, name: String, owner: PlaylistOwner, collaborative: Bool = false,
        trackCount: Int? = nil, images: [SpotifyImage]? = nil, snapshotID: String? = nil
    ) {
        self.id = id
        self.name = name
        self.uri = "spotify:playlist:\(id)"
        self.images = images
        self.owner = owner
        self.collaborative = collaborative
        self.snapshotID = snapshotID
        self.itemCount = ItemCount(total: trackCount)
        self.legacyTrackCount = nil
    }

    /// 清單裡有幾首（包含 podcast 單集與本機檔案）。
    public var trackCount: Int? { itemCount?.total ?? legacyTrackCount?.total }

    /// 開發模式只能讀取自己建立或協作的清單內容，其他清單只拿得到名稱等資料。
    public func isReadable(byUserID userID: String) -> Bool {
        owner.id == userID || collaborative == true
    }
}

/// 帶有專輯資訊的歌曲（播放清單與已按讚的歌曲回傳的是完整 track 物件，裡面有 album）。
public struct TrackWithAlbum: Decodable, Sendable, Hashable {
    public let track: Track
    public let album: Album

    private enum CodingKeys: String, CodingKey { case album, type }

    public init(track: Track, album: Album) {
        self.track = track
        self.album = album
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        // podcast 單集的 type 是 "episode"，不收錄。
        if let type = try container.decodeIfPresent(String.self, forKey: .type), type != "track" {
            throw DecodingError.dataCorruptedError(forKey: .type, in: container, debugDescription: "不是歌曲：\(type)")
        }
        self.track = try Track(from: decoder)
        self.album = try container.decode(Album.self, forKey: .album)
    }
}

/// 播放清單（或已按讚的歌曲）裡的一項。
/// 歌曲下架、podcast 單集、資料不完整的本機檔案都解析成 `track == nil`，之後會被略過。
public struct LibraryItem: Decodable, Sendable {
    public let addedAt: String?
    public let track: TrackWithAlbum?

    private enum CodingKeys: String, CodingKey { case addedAt, item, track }

    public init(track: TrackWithAlbum?, addedAt: String? = nil) {
        self.track = track
        self.addedAt = addedAt
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.addedAt = try container.decodeIfPresent(String.self, forKey: .addedAt)
        let item = (try? container.decodeIfPresent(TrackWithAlbum.self, forKey: .item)) ?? nil
        let legacy = (try? container.decodeIfPresent(TrackWithAlbum.self, forKey: .track)) ?? nil
        self.track = item ?? legacy
    }
}

struct CurrentUser: Decodable, Sendable {
    let id: String
}
