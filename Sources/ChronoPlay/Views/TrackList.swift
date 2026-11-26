import ChronoPlayCore
import SwiftUI

// 藝人頁和播放清單頁共用的曲目列表元件。

enum Column {
    static let index: CGFloat = 44
    static let album: CGFloat = 220
    static let date: CGFloat = 92
    static let kind: CGFloat = 52
    static let saved: CGFloat = 24
    static let duration: CGFloat = 48
}

struct TrackColumnsHeader: View {
    var body: some View {
        HStack(spacing: 12) {
            Text("#").frame(width: Column.index, alignment: .trailing)
            Text("曲名").frame(maxWidth: .infinity, alignment: .leading)
            Text("專輯").frame(width: Column.album, alignment: .leading)
            Text("發行日期").frame(width: Column.date, alignment: .leading)
            Text("類型").frame(width: Column.kind, alignment: .leading)
            Color.clear.frame(width: Column.saved, height: 1)
            Image(systemName: "clock").frame(width: Column.duration, alignment: .trailing)
        }
        .font(.caption.weight(.semibold))
        .foregroundStyle(.secondary)
        .padding(.horizontal, 24)
        .padding(.vertical, 6)
    }
}

struct TrackRow: View {
    let index: Int
    let entry: DiscographyEntry
    let isCurrent: Bool
    let locations: [SavedLocation]

    var body: some View {
        HStack(spacing: 12) {
            Group {
                if isCurrent {
                    Image(systemName: "speaker.wave.2.fill")
                        .foregroundStyle(.tint)
                        .symbolEffect(.variableColor.iterative)
                } else {
                    Text("\(index + 1)")
                        .foregroundStyle(.secondary)
                }
            }
            .monospacedDigit()
            .frame(width: Column.index, alignment: .trailing)

            VStack(alignment: .leading, spacing: 1) {
                Text(entry.track.name)
                    .fontWeight(isCurrent ? .semibold : .regular)
                    .foregroundStyle(isCurrent ? AnyShapeStyle(.tint) : AnyShapeStyle(.primary))
                    .lineLimit(1)
                Text(entry.track.artists.map(\.name).joined(separator: ", "))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            Text(entry.album.name)
                .lineLimit(1)
                .frame(width: Column.album, alignment: .leading)
                .help(entry.album.name)

            Text(entry.release.description)
                .monospacedDigit()
                .frame(width: Column.date, alignment: .leading)

            KindBadge(kind: entry.kind)
                .frame(width: Column.kind, alignment: .leading)

            SavedIndicator(locations: locations)
                .frame(width: Column.saved)

            Text(Self.format(ms: entry.track.durationMs))
                .monospacedDigit()
                .foregroundStyle(.secondary)
                .frame(width: Column.duration, alignment: .trailing)
        }
        .padding(.vertical, 2)
    }

    static func format(ms: Int) -> String {
        let seconds = ms / 1000
        return String(format: "%d:%02d", seconds / 60, seconds % 60)
    }
}

/// 和官方 app 一樣：已收藏的歌曲顯示綠色打勾，按一下列出它在哪些清單。
private struct SavedIndicator: View {
    let locations: [SavedLocation]
    @ViewState private var isShowingLocations = false

    var body: some View {
        if locations.isEmpty {
            Color.clear.frame(height: 1)
        } else {
            Button {
                isShowingLocations = true
            } label: {
                Image(systemName: "checkmark.circle.fill")
                    .font(.body)
                    .foregroundStyle(.green)
                    .contentShape(.circle)
            }
            .buttonStyle(.borderless)
            .help(Self.summary(locations))
            .popover(isPresented: $isShowingLocations, arrowEdge: .bottom) {
                SavedLocationsPopover(locations: locations) { isShowingLocations = false }
            }
        }
    }

    static func summary(_ locations: [SavedLocation]) -> String {
        "已儲存在：" + locations.map(\.title).joined(separator: "、")
    }
}

private struct SavedLocationsPopover: View {
    @Environment(AppModel.self) private var model
    let locations: [SavedLocation]
    let dismiss: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("已儲存在")
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
                .padding(.horizontal, 8)
                .padding(.bottom, 2)
            ForEach(locations) { location in
                Button {
                    // 點一下前往那個清單
                    model.selection = location.sidebarItem
                    dismiss()
                } label: {
                    HStack(spacing: 10) {
                        LibraryArtwork(location: location, size: 28)
                        Text(location.title)
                            .lineLimit(1)
                        Spacer(minLength: 0)
                    }
                    .padding(.horizontal, 8)
                    .padding(.vertical, 4)
                    .contentShape(.rect)
                }
                .buttonStyle(.plain)
                .help("前往「\(location.title)」")
            }
        }
        .padding(10)
        .frame(minWidth: 220, maxWidth: 320)
    }
}

extension SavedLocation {
    var title: String {
        switch self {
        case .liked: "已按讚的歌曲"
        case .playlist(let playlist): playlist.name
        }
    }

    var sidebarItem: SidebarItem {
        switch self {
        case .liked: .likedSongs
        case .playlist(let playlist): .playlist(playlist.id)
        }
    }
}

/// 播放清單封面；「已按讚的歌曲」沒有封面，畫一個漸層愛心。
struct LibraryArtwork: View {
    let location: SavedLocation
    let size: CGFloat

    var body: some View {
        switch location {
        case .liked:
            RoundedRectangle(cornerRadius: size * 0.18)
                .fill(LinearGradient(colors: [.indigo, .purple, .cyan.opacity(0.8)], startPoint: .topLeading, endPoint: .bottomTrailing))
                .overlay(
                    Image(systemName: "heart.fill")
                        .font(.system(size: size * 0.42))
                        .foregroundStyle(.white)
                )
                .frame(width: size, height: size)
        case .playlist(let playlist):
            ArtworkView(images: playlist.images, size: size)
        }
    }
}

struct KindBadge: View {
    let kind: ReleaseKind

    var body: some View {
        Text(kind.shortLabel)
            .font(.caption2.weight(.medium))
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .foregroundStyle(color)
            .background(color.opacity(0.15), in: .capsule)
    }

    private var color: Color {
        switch kind {
        case .album: .blue
        case .single: .green
        case .appearsOn: .orange
        }
    }
}

extension View {
    /// 右鍵選單「從這首開始連續播放」，以及雙擊／Return 從那首開始播。
    func playOnActivate(entries: [DiscographyEntry], model: AppModel) -> some View {
        let find = { (ids: Set<DiscographyEntry.ID>) in entries.first { ids.contains($0.id) } }
        return contextMenu(forSelectionType: DiscographyEntry.ID.self) { ids in
            if let entry = find(ids) {
                Button("從這首開始連續播放", systemImage: "play.fill") {
                    Task { await model.play(from: entry) }
                }
            }
        } primaryAction: { ids in
            if let entry = find(ids) {
                Task { await model.play(from: entry) }
            }
        }
    }
}
