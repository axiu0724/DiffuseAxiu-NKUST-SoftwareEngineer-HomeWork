import ChronoPlayCore
import SwiftUI

struct ArtistDetailView: View {
    @Environment(AppModel.self) private var model
    @ViewState private var selection: Set<DiscographyEntry.ID> = []

    var body: some View {
        let entries = model.visibleTimeline
        let currentID = model.player.currentEntry?.id

        VStack(spacing: 0) {
            ArtistHeader(entries: entries)
            Divider()
            if let progress = model.loadingProgress {
                LoadingView(done: progress.done, total: progress.total)
            } else if entries.isEmpty {
                ContentUnavailableView("沒有符合的歌曲", systemImage: "music.note.list", description: Text("試著打開其他發行類型。"))
            } else {
                TrackColumnsHeader()
                List(selection: $selection) {
                    ForEach(Self.groupByYear(entries), id: \.year) { group in
                        Section(group.year) {
                            ForEach(group.rows, id: \.entry.id) { row in
                                TrackRow(index: row.index, entry: row.entry, isCurrent: row.entry.id == currentID)
                                    .tag(row.entry.id)
                            }
                        }
                    }
                }
                .listStyle(.inset)
                .contextMenu(forSelectionType: DiscographyEntry.ID.self) { ids in
                    if let entry = entry(for: ids, in: entries) {
                        Button("從這首開始連續播放", systemImage: "play.fill") {
                            Task { await model.play(from: entry) }
                        }
                    }
                } primaryAction: { ids in
                    // 雙擊或按 Return：從這首開始播
                    if let entry = entry(for: ids, in: entries) {
                        Task { await model.play(from: entry) }
                    }
                }
            }
        }
        .navigationTitle(model.selectedArtist?.name ?? "")
    }

    private func entry(for ids: Set<DiscographyEntry.ID>, in entries: [DiscographyEntry]) -> DiscographyEntry? {
        entries.first { ids.contains($0.id) }
    }

    struct YearGroup {
        let year: String
        let rows: [(index: Int, entry: DiscographyEntry)]
    }

    static func groupByYear(_ entries: [DiscographyEntry]) -> [YearGroup] {
        var groups: [YearGroup] = []
        var rows: [(index: Int, entry: DiscographyEntry)] = []
        var year: String?
        for (index, entry) in entries.enumerated() {
            let y = entry.release.yearText
            if y != year, let year {
                groups.append(YearGroup(year: year, rows: rows))
                rows = []
            }
            year = y
            rows.append((index, entry))
        }
        if let year { groups.append(YearGroup(year: year, rows: rows)) }
        return groups
    }
}

private struct ArtistHeader: View {
    @Environment(AppModel.self) private var model
    let entries: [DiscographyEntry]

    var body: some View {
        let albumCount = Set(entries.map(\.album.id)).count

        HStack(alignment: .center, spacing: 20) {
            ArtworkView(images: model.selectedArtist?.images, size: 112, shape: .circle)
                .shadow(color: .black.opacity(0.2), radius: 12, y: 6)

            VStack(alignment: .leading, spacing: 10) {
                Text(model.selectedArtist?.name ?? "")
                    .font(.largeTitle.bold())
                    .lineLimit(1)

                if let first = entries.first, let last = entries.last {
                    Text("共 \(entries.count) 首 · \(albumCount) 張發行 · \(first.release.yearText)–\(last.release.yearText)")
                        .foregroundStyle(.secondary)
                }

                GlassEffectContainer(spacing: 8) {
                    HStack(spacing: 8) {
                        Button {
                            Task { await model.play() }
                        } label: {
                            Label("從最舊播到最新", systemImage: "play.fill")
                                .padding(.horizontal, 4)
                        }
                        .buttonStyle(.glassProminent)
                        .controlSize(.large)
                        .disabled(entries.isEmpty)

                        KindFilter()
                    }
                }
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 28)
        .padding(.vertical, 20)
    }
}

/// 發行類型的開關（專輯／單曲與 EP／客串）。
private struct KindFilter: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        ForEach(ReleaseKind.allCases) { kind in
            let isOn = model.enabledKinds.contains(kind)
            Button {
                if isOn {
                    // 至少保留一種類型
                    if model.enabledKinds.count > 1 { model.enabledKinds.remove(kind) }
                } else {
                    model.enabledKinds.insert(kind)
                }
            } label: {
                Label(kind.label, systemImage: isOn ? "checkmark.circle.fill" : "circle")
            }
            .buttonStyle(.glass)
            .controlSize(.large)
            .help(isOn ? "不收錄\(kind.label)" : "收錄\(kind.label)")
        }
    }
}

private struct LoadingView: View {
    let done: Int
    let total: Int

    var body: some View {
        VStack(spacing: 12) {
            if total > 0 {
                ProgressView(value: Double(done), total: Double(total))
                    .frame(width: 260)
                Text("正在讀取作品：\(done) / \(total) 張發行")
            } else {
                ProgressView()
                Text("正在讀取作品清單…")
            }
        }
        .foregroundStyle(.secondary)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

// MARK: - 曲目列

private enum Column {
    static let index: CGFloat = 44
    static let album: CGFloat = 220
    static let date: CGFloat = 92
    static let kind: CGFloat = 52
    static let duration: CGFloat = 48
}

private struct TrackColumnsHeader: View {
    var body: some View {
        HStack(spacing: 12) {
            Text("#").frame(width: Column.index, alignment: .trailing)
            Text("曲名").frame(maxWidth: .infinity, alignment: .leading)
            Text("專輯").frame(width: Column.album, alignment: .leading)
            Text("發行日期").frame(width: Column.date, alignment: .leading)
            Text("類型").frame(width: Column.kind, alignment: .leading)
            Image(systemName: "clock").frame(width: Column.duration, alignment: .trailing)
        }
        .font(.caption.weight(.semibold))
        .foregroundStyle(.secondary)
        .padding(.horizontal, 24)
        .padding(.vertical, 6)
    }
}

private struct TrackRow: View {
    let index: Int
    let entry: DiscographyEntry
    let isCurrent: Bool

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

private struct KindBadge: View {
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
