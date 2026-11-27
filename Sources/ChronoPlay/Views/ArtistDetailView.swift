import ChronoPlayCore
import SwiftUI

struct ArtistDetailView: View {
    @Environment(AppModel.self) private var model
    @ViewState private var selection: Set<DiscographyEntry.ID> = []

    var body: some View {
        // 過濾、分段都在 AppModel 算好了，這裡不再每次重算。
        let display = model.timelineDisplay
        let entries = display.entries
        let currentID = model.player.currentEntry?.id

        VStack(spacing: 0) {
            ArtistHeader(entries: entries, albumCount: display.albumCount)
            Divider()
            if let progress = model.loadingProgress {
                LoadingView(done: progress.done, total: progress.total)
            } else if entries.isEmpty {
                ContentUnavailableView("沒有符合的歌曲", systemImage: "music.note.list", description: Text("試著打開其他發行類型。"))
            } else {
                TrackColumnsHeader()
                List(selection: $selection) {
                    ForEach(display.groups, id: \.year) { group in
                        Section(group.year) {
                            ForEach(group.rows, id: \.entry.id) { row in
                                TrackRow(
                                    index: row.index, entry: row.entry,
                                    isCurrent: row.entry.id == currentID,
                                    locations: model.locations(of: row.entry)
                                )
                                .tag(row.entry.id)
                            }
                        }
                    }
                }
                .listStyle(.inset)
                .playOnActivate(entries: entries, model: model)
            }
        }
        .navigationTitle(model.selectedArtist?.name ?? "")
    }
}

private struct ArtistHeader: View {
    @Environment(AppModel.self) private var model
    let entries: [DiscographyEntry]
    let albumCount: Int

    var body: some View {
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
