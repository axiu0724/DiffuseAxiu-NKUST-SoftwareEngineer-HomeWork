@testable import ChronoPlayCore
import Foundation

enum Fixture {
    static let artistID = "artist-1"
    static let artist = SimpleArtist(id: artistID, name: "主角")
    static let other = SimpleArtist(id: "artist-2", name: "別人")

    static func album(
        _ id: String, _ name: String? = nil, type: String = "album",
        date: String, precision: ReleaseDatePrecision = .day
    ) -> Album {
        Album(id: id, name: name ?? id, albumType: type, releaseDate: date, releaseDatePrecision: precision, artists: [artist])
    }

    static func track(_ id: String, disc: Int = 1, number: Int, artists: [SimpleArtist] = [artist]) -> Track {
        Track(id: id, name: id, discNumber: disc, trackNumber: number, artists: artists)
    }

    static func entry(_ album: Album, _ track: Track, kind: ReleaseKind = .album) -> DiscographyEntry {
        DiscographyEntry(track: track, album: album, kind: kind)
    }
}

/// 假的目錄 API：依 include_groups 回傳設定好的專輯，並記錄呼叫。
struct FakeCatalog: CatalogAPI {
    var ownAlbums: [Album] = []
    var appearsOn: [Album] = []
    var tracks: [String: [Track]] = [:]

    func artistAlbums(artistID: String, groups: String) async throws -> [Album] {
        groups == "appears_on" ? appearsOn : ownAlbums
    }

    func albumTracks(albumID: String) async throws -> [Track] {
        tracks[albumID] ?? []
    }
}

/// 假的播放器：記錄收到的指令，並回傳設定好的播放狀態。
actor FakePlayer: PlayerAPI {
    enum Call: Equatable {
        case play([String]), resume, pause, queue(String), next, previous
    }

    private(set) var calls: [Call] = []
    var current: PlaybackState?
    var playError: (any Error)?
    var stateError: (any Error)?

    func setCurrent(uri: String?, isPlaying: Bool = true) {
        current = uri.map { PlaybackState(isPlaying: isPlaying, progressMs: 1000, item: PlayingItem(uri: $0, name: $0, durationMs: 200_000)) }
    }

    func setPlayError(_ error: (any Error)?) { playError = error }
    func setStateError(_ error: (any Error)?) { stateError = error }

    func play(uris: [String], deviceID: String?) async throws {
        if let playError { throw playError }
        calls.append(.play(uris))
        setCurrent(uri: uris.first)
    }

    func resume(deviceID: String?) async throws { calls.append(.resume) }
    func pause(deviceID: String?) async throws { calls.append(.pause) }
    func addToQueue(uri: String, deviceID: String?) async throws { calls.append(.queue(uri)) }
    func skipToNext(deviceID: String?) async throws { calls.append(.next) }
    func skipToPrevious(deviceID: String?) async throws { calls.append(.previous) }
    func playbackState() async throws -> PlaybackState? {
        if let stateError { throw stateError }
        return current
    }
}
