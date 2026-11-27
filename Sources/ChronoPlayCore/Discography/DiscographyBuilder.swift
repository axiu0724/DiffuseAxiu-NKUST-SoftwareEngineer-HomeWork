import Foundation

/// 建立作品時間軸需要的 API。SpotifyClient 會實作它，測試時可以換成假資料。
public protocol CatalogAPI: Sendable {
    /// `groups` 是 include_groups 參數，例如 "album,single" 或 "appears_on"。必須回傳所有分頁。
    func artistAlbums(artistID: String, groups: String) async throws -> [Album]
    /// 必須回傳所有分頁。
    func albumTracks(albumID: String) async throws -> [Track]
}

public enum DiscographyBuilder {
    /// 抓出藝人的作品並由舊到新排好。
    ///
    /// - `album_group` 欄位已被 Spotify 移除，所以「自己的作品」和「客串」分兩次查。
    /// - 客串專輯只保留這位藝人有參與的曲目。
    /// - `progress(已完成, 總數)` 以專輯為單位回報進度。
    public static func build(
        artistID: String,
        kinds: Set<ReleaseKind>,
        api: some CatalogAPI,
        maxConcurrentRequests: Int = 4,
        progress: (@Sendable (Int, Int) -> Void)? = nil
    ) async throws -> [DiscographyEntry] {
        var albums: [(Album, ReleaseKind)] = []
        var seen = Set<String>()

        // 兩份清單互不相依，同時抓；合併時仍先放自己的作品，去重時自己的作品優先。
        async let ownAlbums: [Album] = kinds.isDisjoint(with: [.album, .single])
            ? [] : api.artistAlbums(artistID: artistID, groups: "album,single")
        async let guestAlbums: [Album] = kinds.contains(.appearsOn)
            ? api.artistAlbums(artistID: artistID, groups: "appears_on") : []

        for album in try await ownAlbums {
            let kind: ReleaseKind = album.albumType == "single" ? .single : .album
            if kinds.contains(kind), seen.insert(album.id).inserted {
                albums.append((album, kind))
            }
        }
        for album in try await guestAlbums {
            if seen.insert(album.id).inserted {
                albums.append((album, .appearsOn))
            }
        }

        let total = albums.count
        progress?(0, total)

        // 有限並行抓每張專輯的曲目，避免一次送出太多請求被 429 擋下。
        var entries: [DiscographyEntry] = []
        try await withThrowingTaskGroup(of: [DiscographyEntry].self) { group in
            var nextIndex = 0
            var finished = 0

            func addTask() {
                let (album, kind) = albums[nextIndex]
                nextIndex += 1
                group.addTask {
                    let tracks = try await api.albumTracks(albumID: album.id)
                    return makeEntries(album: album, kind: kind, tracks: tracks, artistID: artistID)
                }
            }

            for _ in 0..<min(maxConcurrentRequests, total) { addTask() }
            while let result = try await group.next() {
                entries.append(contentsOf: result)
                finished += 1
                progress?(finished, total)
                if nextIndex < total { addTask() }
            }
        }

        return ChronologicalSorter.sort(entries)
    }

    /// 把一張專輯的曲目轉成 entry。客串專輯只留下有這位藝人的曲目；本機檔案和不能播的曲目會略過。
    public static func makeEntries(album: Album, kind: ReleaseKind, tracks: [Track], artistID: String) -> [DiscographyEntry] {
        tracks
            .filter { $0.isLocal != true && $0.isPlayable != false }
            .filter { kind != .appearsOn || $0.artists.contains { $0.id == artistID } }
            .map { DiscographyEntry(track: $0, album: album, kind: kind) }
    }
}
