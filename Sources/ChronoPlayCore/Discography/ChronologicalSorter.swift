import Foundation

/// 發行類型。順序也是同一天發行時的排序順序。
public enum ReleaseKind: Int, Sendable, Hashable, CaseIterable, Comparable, Identifiable {
    case album = 0
    case single = 1
    case appearsOn = 2

    public var id: Int { rawValue }

    public var label: String {
        switch self {
        case .album: "專輯"
        case .single: "單曲與 EP"
        case .appearsOn: "客串"
        }
    }

    public var shortLabel: String {
        switch self {
        case .album: "專輯"
        case .single: "單曲"
        case .appearsOn: "客串"
        }
    }

    public static func < (lhs: ReleaseKind, rhs: ReleaseKind) -> Bool {
        lhs.rawValue < rhs.rawValue
    }
}

/// 時間軸上的一首歌：曲目本身加上它所屬的專輯與類型。
/// 同一首歌出現在不同專輯（原版、豪華版、重製版）時，會是不同的 entry。
public struct DiscographyEntry: Sendable, Hashable, Identifiable {
    public let track: Track
    public let album: Album
    public let kind: ReleaseKind
    /// 同一首歌在播放清單裡第幾次出現（從 0 開始）。藝人時間軸一律是 0。
    public let occurrence: Int
    /// 建立時就算好存起來：列表、排序與播放會反覆讀取，不要每次都重組字串、重新解析日期。
    public let id: String
    public let release: ReleaseDate

    public init(track: Track, album: Album, kind: ReleaseKind, occurrence: Int = 0) {
        self.init(track: track, album: album, kind: kind, occurrence: occurrence, baseID: Self.baseID(track: track, album: album))
    }

    /// 已經算好 `baseID(track:album:)` 時用這個，避免再組一次字串。
    init(track: Track, album: Album, kind: ReleaseKind, occurrence: Int, baseID: String) {
        self.track = track
        self.album = album
        self.kind = kind
        self.occurrence = occurrence
        self.id = occurrence == 0 ? baseID : "\(baseID)#\(occurrence)"
        self.release = album.release
    }

    /// 不含出現次數的 id，同一張專輯的同一首歌會相同。
    static func baseID(track: Track, album: Album) -> String {
        "\(album.id)/\(track.discNumber)/\(track.trackNumber)/\(track.uri)"
    }
}

public enum ChronologicalSorter {
    /// 由舊到新排序。排序鍵依序是：
    /// 發行日期 → 類型（專輯、單曲、客串）→ 專輯名稱 → 專輯 id → 第幾片 → 第幾軌。
    public static func sort(_ entries: [DiscographyEntry]) -> [DiscographyEntry] {
        entries.sorted(by: areInIncreasingOrder)
    }

    /// `release` 是建立 entry 時就解析好的，比較時不會重新解析日期字串。
    public static func areInIncreasingOrder(_ a: DiscographyEntry, _ b: DiscographyEntry) -> Bool {
        if a.release != b.release { return a.release < b.release }
        if a.kind != b.kind { return a.kind < b.kind }
        if a.album.id != b.album.id {
            let byName = a.album.name.compare(b.album.name, options: [.caseInsensitive, .numeric])
            if byName != .orderedSame { return byName == .orderedAscending }
            return a.album.id < b.album.id
        }
        if a.track.discNumber != b.track.discNumber { return a.track.discNumber < b.track.discNumber }
        return a.track.trackNumber < b.track.trackNumber
    }
}
