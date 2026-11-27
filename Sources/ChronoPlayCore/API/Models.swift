import Foundation

// Spotify Web API 回傳的資料模型。
// JSONDecoder 使用 .convertFromSnakeCase，所以 album_type 對應 albumType，以此類推。
// 2026 年 2 月起開發模式移除了 popularity、followers、available_markets、album_group 等欄位，這裡都不使用。

public struct SpotifyImage: Codable, Sendable, Hashable {
    public let url: URL
    public let width: Int?
    public let height: Int?

    public init(url: URL, width: Int? = nil, height: Int? = nil) {
        self.url = url
        self.width = width
        self.height = height
    }
}

extension Array where Element == SpotifyImage {
    /// 挑一張寬度最接近 `target` 的圖（Spotify 通常給 640／300／64 三種尺寸）。
    public func best(for target: Int) -> SpotifyImage? {
        self.min { abs(($0.width ?? target) - target) < abs(($1.width ?? target) - target) }
    }
}

public struct SimpleArtist: Codable, Sendable, Hashable, Identifiable {
    public let id: String?
    public let name: String
    public let uri: String?

    public init(id: String?, name: String, uri: String? = nil) {
        self.id = id
        self.name = name
        self.uri = uri
    }
}

public struct Artist: Codable, Sendable, Hashable, Identifiable {
    public let id: String
    public let name: String
    public let uri: String
    public let images: [SpotifyImage]?
    public let genres: [String]?

    public init(id: String, name: String, uri: String? = nil, images: [SpotifyImage]? = nil, genres: [String]? = nil) {
        self.id = id
        self.name = name
        self.uri = uri ?? "spotify:artist:\(id)"
        self.images = images
        self.genres = genres
    }
}

public enum ReleaseDatePrecision: String, Codable, Sendable {
    case year, month, day
}

public struct Album: Codable, Sendable, Hashable, Identifiable {
    public let id: String
    public let name: String
    public let uri: String
    public let albumType: String
    public let releaseDate: String
    public let releaseDatePrecision: ReleaseDatePrecision
    public let totalTracks: Int?
    public let images: [SpotifyImage]?
    public let artists: [SimpleArtist]

    public init(
        id: String, name: String, uri: String? = nil, albumType: String,
        releaseDate: String, releaseDatePrecision: ReleaseDatePrecision,
        totalTracks: Int? = nil, images: [SpotifyImage]? = nil, artists: [SimpleArtist] = []
    ) {
        self.id = id
        self.name = name
        self.uri = uri ?? "spotify:album:\(id)"
        self.albumType = albumType
        self.releaseDate = releaseDate
        self.releaseDatePrecision = releaseDatePrecision
        self.totalTracks = totalTracks
        self.images = images
        self.artists = artists
    }

    public var release: ReleaseDate {
        ReleaseDate(string: releaseDate, precision: releaseDatePrecision)
    }
}

public struct Track: Codable, Sendable, Hashable, Identifiable {
    public let id: String?
    public let name: String
    public let uri: String
    public let durationMs: Int
    public let discNumber: Int
    public let trackNumber: Int
    public let artists: [SimpleArtist]
    public let isPlayable: Bool?
    public let isLocal: Bool?

    public init(
        id: String?, name: String, uri: String? = nil, durationMs: Int = 180_000,
        discNumber: Int = 1, trackNumber: Int, artists: [SimpleArtist] = [],
        isPlayable: Bool? = nil, isLocal: Bool? = nil
    ) {
        self.id = id
        self.name = name
        self.uri = uri ?? "spotify:track:\(id ?? UUID().uuidString)"
        self.durationMs = durationMs
        self.discNumber = discNumber
        self.trackNumber = trackNumber
        self.artists = artists
        self.isPlayable = isPlayable
        self.isLocal = isLocal
    }

    /// 是不是同一段錄音。同一張專輯的不同版本 ID 不同，但歌名、長度（毫秒）和主要藝人都一樣。
    public func isSameRecording(as item: PlayingItem) -> Bool {
        guard let artistID = artists.first?.id, artistID == item.artists?.first?.id else { return false }
        return name == item.name && durationMs == item.durationMs
    }
}

public struct Paging<Item: Decodable & Sendable>: Decodable, Sendable {
    public let items: [Item]
    public let next: URL?
    public let total: Int?
}

struct ArtistSearchResponse: Decodable, Sendable {
    let artists: Paging<Artist>
}

// MARK: - 播放器

public struct Device: Codable, Sendable, Hashable, Identifiable {
    public let id: String?
    public let isActive: Bool
    public let isRestricted: Bool?
    public let name: String
    public let type: String
    public let volumePercent: Int?

    public init(id: String?, isActive: Bool, name: String, type: String = "Computer") {
        self.id = id
        self.isActive = isActive
        self.isRestricted = false
        self.name = name
        self.type = type
        self.volumePercent = nil
    }

    /// SF Symbol 名稱
    public var symbolName: String {
        switch type.lowercased() {
        case "computer": "laptopcomputer"
        case "smartphone": "iphone"
        case "tablet": "ipad"
        case "speaker": "hifispeaker"
        case "tv", "castvideo": "tv"
        case "automobile": "car"
        default: "speaker.wave.2"
        }
    }
}

struct DevicesResponse: Decodable, Sendable {
    let devices: [Device]
}

/// 正在播放的項目（可能是歌曲或 podcast，欄位盡量寬鬆）。
public struct PlayingItem: Decodable, Sendable, Hashable {
    public struct PlayingAlbum: Decodable, Sendable, Hashable {
        public let name: String?
        public let images: [SpotifyImage]?
    }

    public let uri: String
    public let name: String
    public let durationMs: Int?
    public let album: PlayingAlbum?
    public let artists: [SimpleArtist]?

    public init(uri: String, name: String, durationMs: Int? = nil, artists: [SimpleArtist]? = nil) {
        self.uri = uri
        self.name = name
        self.durationMs = durationMs
        self.album = nil
        self.artists = artists
    }
}

public struct PlaybackState: Decodable, Sendable, Hashable {
    public let device: Device?
    public let isPlaying: Bool
    public let progressMs: Int?
    public let item: PlayingItem?

    public init(device: Device? = nil, isPlaying: Bool, progressMs: Int? = nil, item: PlayingItem?) {
        self.device = device
        self.isPlaying = isPlaying
        self.progressMs = progressMs
        self.item = item
    }
}
