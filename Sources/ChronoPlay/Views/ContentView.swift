import AuthenticationServices
import ChronoPlayCore
import SwiftUI

struct ContentView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        @Bindable var model = model

        NavigationSplitView {
            SidebarView()
                .navigationSplitViewColumnWidth(min: 220, ideal: 260, max: 340)
        } detail: {
            DetailView()
        }
        .searchable(text: $model.searchText, placement: .sidebar, prompt: "搜尋藝人")
        .task(id: model.searchText) {
            // 停止打字 0.35 秒後才送出搜尋
            try? await Task.sleep(for: .milliseconds(350))
            guard !Task.isCancelled else { return }
            await model.search()
        }
        .toolbar {
            if model.isLoggedIn {
                ToolbarItem(placement: .primaryAction) {
                    DeviceMenu()
                }
            }
        }
        .alert("發生錯誤", isPresented: Binding(
            get: { model.errorMessage != nil },
            set: { if !$0 { model.errorMessage = nil } }
        )) {
            Button("好") { model.errorMessage = nil }
        } message: {
            Text(model.errorMessage ?? "")
        }
    }
}

private struct DetailView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        Group {
            if !model.isLoggedIn {
                OnboardingView()
            } else {
                switch model.selection {
                case .artist:
                    ArtistDetailView()
                case .likedSongs, .playlist:
                    PlaylistDetailView(item: model.selection!)
                case nil:
                    ContentUnavailableView(
                        "搜尋一位藝人",
                        systemImage: "music.mic",
                        description: Text("在左上角輸入藝人名稱，就能把他的作品從最舊排到最新，一路連續播放。也可以從左側打開你的播放清單。")
                    )
                }
            }
        }
        // 撐滿整個主畫面，播放列才會貼在視窗底部（否則會跟著置中的內容浮在中間）
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        // 讓內容捲到玻璃播放列底下，看得到 Liquid Glass 的折射效果
        .safeAreaInset(edge: .bottom, spacing: 0) {
            if model.isLoggedIn {
                NowPlayingBar()
            }
        }
    }
}

struct SidebarView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        @Bindable var model = model

        List(selection: $model.selection) {
            if model.isLoggedIn {
                Section("藝人") {
                    if model.searchResults.isEmpty {
                        Text(model.searchText.isEmpty ? "輸入名稱開始搜尋" : (model.hasPendingSearch ? "搜尋中…" : "找不到符合的藝人"))
                            .foregroundStyle(.secondary)
                            .selectionDisabled()
                    }
                    ForEach(model.searchResults) { artist in
                        HStack(spacing: 10) {
                            ArtworkView(images: artist.images, size: 32, shape: .circle)
                            Text(artist.name)
                                .lineLimit(1)
                        }
                        .tag(SidebarItem.artist(artist.id))
                    }
                }
                LibrarySection()
            } else {
                Text("請先登入 Spotify")
                    .foregroundStyle(.secondary)
                    .selectionDisabled()
            }
        }
        .navigationTitle("ChronoPlay")
    }
}

/// 側邊欄的「我的播放清單」：已按讚的歌曲、自己的清單，最後是只能看名稱的追蹤清單。
private struct LibrarySection: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        let library = model.library
        let readable = library.playlists.filter { !library.unreadable.contains($0.id) }
        let followed = library.playlists.filter { library.unreadable.contains($0.id) }

        Section {
            if model.needsLibraryAuthorization {
                ReauthorizeRow()
            } else {
                LibraryRow(location: .liked, detail: model.likedEntries.map { "\($0.count) 首" })
                    .tag(SidebarItem.likedSongs)

                if let progress = model.libraryProgress {
                    HStack(spacing: 8) {
                        ProgressView().controlSize(.small)
                        Text(progress.total > 0 ? "正在讀取清單 \(progress.done) / \(progress.total)" : "正在讀取清單…")
                    }
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .selectionDisabled()
                }

                ForEach(readable) { playlist in
                    LibraryRow(
                        location: .playlist(playlist),
                        detail: (model.playlistEntries[playlist.id]?.count ?? playlist.trackCount).map { "\($0) 首" }
                    )
                    .tag(SidebarItem.playlist(playlist.id))
                }
                ForEach(followed) { playlist in
                    LibraryRow(location: .playlist(playlist), detail: playlist.owner.displayName, isDimmed: true)
                        .tag(SidebarItem.playlist(playlist.id))
                        .help("追蹤的清單：Spotify 開發模式無法讀取它的內容")
                }
            }
        } header: {
            HStack {
                Text("我的播放清單")
                Spacer()
                if !model.needsLibraryAuthorization {
                    Button("重新整理", systemImage: "arrow.clockwise") {
                        Task { await model.refreshLibrary() }
                    }
                    .labelStyle(.iconOnly)
                    .buttonStyle(.borderless)
                    .help("重新讀取播放清單，以及歌曲是否已收藏")
                    .disabled(model.libraryProgress != nil)
                }
            }
        }
    }
}

private struct LibraryRow: View {
    let location: SavedLocation
    let detail: String?
    var isDimmed = false

    var body: some View {
        HStack(spacing: 10) {
            LibraryArtwork(location: location, size: 32)
                .opacity(isDimmed ? 0.6 : 1)
            VStack(alignment: .leading, spacing: 1) {
                Text(location.title)
                    .lineLimit(1)
                    .foregroundStyle(isDimmed ? .secondary : .primary)
                if let detail {
                    Text(detail)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            }
        }
    }
}

/// 舊版登入沒有讀取清單的權限，請使用者重新登入一次。
private struct ReauthorizeRow: View {
    @Environment(AppModel.self) private var model
    @Environment(\.webAuthenticationSession) private var webAuthenticationSession

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("要顯示你的播放清單，需要重新登入，允許 ChronoPlay 讀取清單。")
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(2...4)
                .fixedSize(horizontal: false, vertical: true)
            Button {
                Task { await model.login(using: webAuthenticationSession) }
            } label: {
                if model.isLoggingIn {
                    ProgressView().controlSize(.small)
                } else {
                    Label("重新登入 Spotify", systemImage: "person.crop.circle.badge.checkmark")
                }
            }
            .buttonStyle(.glass)
            .disabled(model.isLoggingIn)
        }
        .padding(.vertical, 4)
        .selectionDisabled()
    }
}

/// 封面或頭像。
struct ArtworkView: View {
    enum Shape { case circle, rounded }

    let images: [SpotifyImage]?
    let size: CGFloat
    var shape: Shape = .rounded

    var body: some View {
        let url = images?.best(for: Int(size * 2))?.url
        AsyncImage(url: url) { image in
            image.resizable().scaledToFill()
        } placeholder: {
            Rectangle()
                .fill(.quaternary)
                .overlay(Image(systemName: "music.note").foregroundStyle(.secondary))
        }
        .frame(width: size, height: size)
        .clipShape(shape == .circle ? AnyShape(Circle()) : AnyShape(RoundedRectangle(cornerRadius: size * 0.18)))
    }
}

struct DeviceMenu: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        let current = model.devices.first { $0.id == model.player.deviceID }
        Menu {
            if model.devices.isEmpty {
                Text("找不到可播放的裝置")
                Button("打開 Spotify", systemImage: "arrow.up.forward.app") { model.openSpotifyApp() }
            } else {
                ForEach(model.devices) { device in
                    Button {
                        Task { await model.select(device: device) }
                    } label: {
                        Label(device.name, systemImage: device.id == model.player.deviceID ? "checkmark" : device.symbolName)
                    }
                }
            }
            Divider()
            Button("重新整理裝置", systemImage: "arrow.clockwise") {
                Task { await model.refreshDevices() }
            }
        } label: {
            Label(current?.name ?? "選擇裝置", systemImage: current?.symbolName ?? "hifispeaker")
                .labelStyle(.titleAndIcon)
        }
        .help("選擇要播放的 Spotify Connect 裝置")
    }
}
