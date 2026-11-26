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
            } else if model.selectedArtistID != nil {
                ArtistDetailView()
            } else {
                ContentUnavailableView(
                    "搜尋一位藝人",
                    systemImage: "music.mic",
                    description: Text("在左上角輸入藝人名稱，就能把他的作品從最舊排到最新，一路連續播放。")
                )
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

        List(selection: $model.selectedArtistID) {
            if model.isLoggedIn {
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
                    .tag(artist.id)
                }
            } else {
                Text("請先登入 Spotify")
                    .foregroundStyle(.secondary)
                    .selectionDisabled()
            }
        }
        .navigationTitle("藝人")
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
        .task { await model.refreshDevices() }
    }
}
