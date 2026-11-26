import ChronoPlayCore
import SwiftUI

/// 底部浮動的 Liquid Glass 播放列。
struct NowPlayingBar: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        let player = model.player

        VStack(spacing: 8) {
            if let error = player.lastError {
                HStack(spacing: 8) {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .foregroundStyle(.yellow)
                    Text(error)
                        .lineLimit(2)
                    Button("關閉", systemImage: "xmark") { player.lastError = nil }
                        .labelStyle(.iconOnly)
                        .buttonStyle(.borderless)
                }
                .font(.callout)
                .padding(.horizontal, 14)
                .padding(.vertical, 8)
                .glassEffect(.regular.tint(.yellow.opacity(0.15)), in: .capsule)
            }

            GlassEffectContainer(spacing: 10) {
                HStack(spacing: 16) {
                    NowPlayingInfo()
                        .frame(maxWidth: .infinity, alignment: .leading)

                    TransportControls()

                    HStack(spacing: 12) {
                        PlaybackProgress()
                        SequenceStatus()
                    }
                    .frame(maxWidth: .infinity, alignment: .trailing)
                }
                .padding(.horizontal, 14)
                .padding(.vertical, 10)
                .glassEffect(.regular, in: .capsule)
            }
        }
        .padding(.horizontal, 20)
        .padding(.bottom, 16)
        .padding(.top, 8)
    }
}

private struct NowPlayingInfo: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        let player = model.player
        let entry = player.currentEntry
        let item = player.state?.item

        HStack(spacing: 12) {
            ArtworkView(images: entry?.album.images ?? item?.album?.images, size: 44)
            VStack(alignment: .leading, spacing: 2) {
                Text(entry?.track.name ?? item?.name ?? "沒有正在播放的歌曲")
                    .font(.headline)
                    .lineLimit(1)
                Group {
                    if let entry {
                        Text("\(entry.album.name) · \(entry.release.description)")
                    } else if let item {
                        Text([item.artists?.map(\.name).joined(separator: ", "), item.album?.name].compactMap { $0 }.joined(separator: " · "))
                    } else {
                        Text("選一位藝人，按「從最舊播到最新」")
                    }
                }
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(1)
            }
        }
    }
}

private struct TransportControls: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        let player = model.player
        HStack(spacing: 8) {
            Button("上一首", systemImage: "backward.fill") { Task { await player.previous() } }
            Button(player.state?.isPlaying == true ? "暫停" : "播放",
                   systemImage: player.state?.isPlaying == true ? "pause.fill" : "play.fill") {
                Task { await player.togglePlayPause() }
            }
            .controlSize(.extraLarge)
            Button("下一首", systemImage: "forward.fill") { Task { await player.next() } }
        }
        .labelStyle(.iconOnly)
        .buttonStyle(.glass)
        .buttonBorderShape(.circle)
        .controlSize(.large)
        .disabled(player.state == nil)
    }
}

private struct PlaybackProgress: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        let player = model.player
        // 兩次輪詢之間，用本機時間推算進度，讓進度條平順地前進
        TimelineView(.periodic(from: .now, by: 1)) { context in
            let duration = Double(player.state?.item?.durationMs ?? 0) / 1000
            let elapsed = estimatedElapsed(at: context.date)
            HStack(spacing: 8) {
                Text(Self.format(elapsed)).monospacedDigit().fixedSize()
                ProgressView(value: min(elapsed, duration), total: max(duration, 1))
                    .frame(width: 140)
                Text(Self.format(duration)).monospacedDigit().fixedSize()
            }
            .font(.caption)
            .foregroundStyle(.secondary)
        }
    }

    private func estimatedElapsed(at date: Date) -> Double {
        let player = model.player
        guard let state = player.state else { return 0 }
        var seconds = Double(state.progressMs ?? 0) / 1000
        if state.isPlaying, let fetched = player.stateFetchedAt {
            seconds += date.timeIntervalSince(fetched)
        }
        return seconds
    }

    static func format(_ seconds: Double) -> String {
        let s = max(Int(seconds), 0)
        return String(format: "%d:%02d", s / 60, s % 60)
    }
}

/// 顯示連續播放的進度，或離開／播完時提供繼續的按鈕。
private struct SequenceStatus: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        let player = model.player
        if let plan = player.plan {
            switch plan.status {
            case .playing:
                Label("第 \(plan.currentIndex + 1) / \(plan.uris.count) 首", systemImage: "list.number")
                    .font(.caption.monospacedDigit())
                    .fixedSize()
                    .foregroundStyle(.secondary)
                    .help("連續播放中：會依時間順序一路播完")
            case .detached:
                Button("從第 \(plan.currentIndex + 1) 首繼續", systemImage: "arrow.uturn.forward") {
                    Task { await player.resumeSequence(windowSize: model.windowSize) }
                }
                .buttonStyle(.glass)
                .help("你在其他地方換了歌，已離開連續播放")
            case .finished:
                Button("全部播完，重新開始", systemImage: "arrow.counterclockwise") {
                    Task { await player.resumeSequence(windowSize: model.windowSize) }
                }
                .buttonStyle(.glass)
            }
        }
    }
}
