import ChronoPlayCore
import SwiftUI

/// 播放清單或「已按讚的歌曲」：依清單原本的順序列出歌曲，可以從頭或從任一首開始連續播放。
struct PlaylistDetailView: View {
    @Environment(AppModel.self) private var model
    @ViewState private var selection: Set<DiscographyEntry.ID> = []
    let item: SidebarItem

    var body: some View {
        let entries = model.currentEntries
        let currentID = model.player.currentEntry?.id

        VStack(spacing: 0) {
            PlaylistHeader(item: item, entries: entries)
            Divider()
            if isUnreadable {
                ContentUnavailableView(
                    "無法讀取這個清單的內容",
                    systemImage: "lock",
                    description: Text("Spotify 開發模式只能讀取你自己建立或協作的播放清單。這個清單請在官方 Spotify app 播放。")
                )
            } else if isLoading {
                VStack(spacing: 12) {
                    ProgressView()
                    Text("正在讀取清單…")
                }
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if entries.isEmpty {
                ContentUnavailableView("清單裡沒有可播放的歌曲", systemImage: "music.note.list")
            } else {
                TrackColumnsHeader()
                List(selection: $selection) {
                    // enumerated() 本身就是 RandomAccessCollection，不用每次重繪都複製成 Array。
                    ForEach(entries.enumerated(), id: \.element.id) { index, entry in
                        TrackRow(
                            index: index, entry: entry,
                            isCurrent: entry.id == currentID,
                            locations: model.locations(of: entry)
                        )
                        .tag(entry.id)
                    }
                }
                .listStyle(.inset)
                .playOnActivate(entries: entries, model: model)
            }
        }
        .navigationTitle(title)
        .onChange(of: item) { selection = [] }
    }

    private var title: String {
        switch item {
        case .likedSongs: "已按讚的歌曲"
        case .playlist(let id): model.playlist(id: id)?.name ?? ""
        case .artist: ""
        }
    }

    private var isUnreadable: Bool {
        if case .playlist(let id) = item { model.library.unreadable.contains(id) } else { false }
    }

    private var isLoading: Bool {
        switch item {
        case .likedSongs: model.likedEntries == nil
        case .playlist(let id): model.playlistEntries[id] == nil && model.libraryProgress != nil
        case .artist: false
        }
    }
}

private struct PlaylistHeader: View {
    @Environment(AppModel.self) private var model
    let item: SidebarItem
    let entries: [DiscographyEntry]

    var body: some View {
        HStack(alignment: .center, spacing: 20) {
            LibraryArtwork(location: location ?? .liked, size: 112)
                .shadow(color: .black.opacity(0.2), radius: 12, y: 6)

            VStack(alignment: .leading, spacing: 10) {
                Text(location?.title ?? "")
                    .font(.largeTitle.bold())
                    .lineLimit(1)

                Text(subtitle)
                    .foregroundStyle(.secondary)

                GlassEffectContainer(spacing: 8) {
                    HStack(spacing: 8) {
                        Button {
                            Task { await model.play() }
                        } label: {
                            Label("依清單順序播放", systemImage: "play.fill")
                                .padding(.horizontal, 4)
                        }
                        .buttonStyle(.glassProminent)
                        .controlSize(.large)
                        .disabled(entries.isEmpty)

                        Button {
                            Task { await model.refreshLibrary() }
                        } label: {
                            Label("重新整理", systemImage: "arrow.clockwise")
                        }
                        .buttonStyle(.glass)
                        .controlSize(.large)
                        .help("重新讀取所有播放清單和已按讚的歌曲")
                        .disabled(model.libraryProgress != nil || model.isLoadingLiked)
                    }
                }
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 28)
        .padding(.vertical, 20)
    }

    private var location: SavedLocation? {
        switch item {
        case .likedSongs: .liked
        case .playlist(let id): model.playlist(id: id).map(SavedLocation.playlist)
        case .artist: nil
        }
    }

    private var subtitle: String {
        var parts: [String] = []
        if case .playlist(let id) = item, let playlist = model.playlist(id: id) {
            if let owner = playlist.owner.displayName { parts.append("由 \(owner) 建立") }
            if playlist.collaborative == true { parts.append("協作清單") }
        }
        if !entries.isEmpty {
            let minutes = model.totalDurationMs(of: item) / 60_000
            parts.append("共 \(entries.count) 首")
            parts.append(minutes >= 60 ? "\(minutes / 60) 小時 \(minutes % 60) 分鐘" : "\(minutes) 分鐘")
        }
        return parts.isEmpty ? " " : parts.joined(separator: " · ")
    }
}
