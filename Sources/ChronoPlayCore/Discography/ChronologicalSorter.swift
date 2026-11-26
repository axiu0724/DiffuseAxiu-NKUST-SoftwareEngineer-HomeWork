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

    public init(track: Track, album: Album, kind: ReleaseKind) {
        self.track = track
        self.album = album
        self.kind = kind
    }

    public var id: String { "\(album.id)/\(track.discNumber)/\(track.trackNumber)/\(track.uri)" }
    public var release: ReleaseDate { album.release }
}

public enum ChronologicalSorter {
    /// 由舊到新排序。排序鍵依序是：
    /// 發行日期 → 類型（專輯、單曲、客串）→ 專輯名稱 → 專輯 id → 第幾片 → 第幾軌。
    public static func sort(_ entries: [DiscographyEntry]) -> [DiscographyEntry] {
        entries.sorted(by: areInIncreasingOrder)
    }

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
