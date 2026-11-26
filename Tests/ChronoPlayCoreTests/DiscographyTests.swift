@testable import ChronoPlayCore
import Testing

@Suite("發行日期")
struct ReleaseDateTests {
    @Test("解析三種精度並正確顯示")
    func parsing() {
        #expect(ReleaseDate(string: "1998-05-21", precision: .day).description == "1998-05-21")
        #expect(ReleaseDate(string: "1998-05", precision: .month).description == "1998-05")
        #expect(ReleaseDate(string: "1998", precision: .year).description == "1998")
        #expect(ReleaseDate(string: "0000", precision: .year).isKnown == false)
    }

    @Test("缺少的月日補 1，同一天時精度高的在前")
    func ordering() {
        let yearOnly = ReleaseDate(string: "1998", precision: .year)
        let jan1 = ReleaseDate(string: "1998-01-01", precision: .day)
        let feb = ReleaseDate(string: "1998-02", precision: .month)
        let dec = ReleaseDate(string: "1997-12-31", precision: .day)
        #expect([feb, yearOnly, jan1, dec].sorted() == [dec, jan1, yearOnly, feb])
    }

    @Test("未知日期排在最後")
    func unknownLast() {
        let unknown = ReleaseDate(string: "0000", precision: .year)
        let recent = ReleaseDate(string: "2026-11-01", precision: .day)
        #expect(recent < unknown)
    }
}

@Suite("時間排序")
struct ChronologicalSorterTests {
    @Test("依發行日期由舊到新，專輯內依片號與軌號")
    func basicOrder() {
        let old = Fixture.album("old", date: "2001-03-01")
        let new = Fixture.album("new", date: "2010-07-15")
        let entries = [
            Fixture.entry(new, Fixture.track("n1", number: 1)),
            Fixture.entry(old, Fixture.track("o-d2-1", disc: 2, number: 1)),
            Fixture.entry(old, Fixture.track("o-d1-2", disc: 1, number: 2)),
            Fixture.entry(old, Fixture.track("o-d1-1", disc: 1, number: 1)),
        ]
        let ids = ChronologicalSorter.sort(entries).map(\.track.id)
        #expect(ids == ["o-d1-1", "o-d1-2", "o-d2-1", "n1"])
    }

    @Test("同一天發行：專輯 → 單曲 → 客串")
    func sameDayKindOrder() {
        let day = "2015-06-01"
        let single = Fixture.album("s", type: "single", date: day)
        let album = Fixture.album("a", date: day)
        let feat = Fixture.album("f", date: day)
        let entries = [
            Fixture.entry(feat, Fixture.track("feat", number: 1), kind: .appearsOn),
            Fixture.entry(single, Fixture.track("single", number: 1), kind: .single),
            Fixture.entry(album, Fixture.track("album", number: 1), kind: .album),
        ]
        #expect(ChronologicalSorter.sort(entries).map(\.track.id) == ["album", "single", "feat"])
    }

    @Test("同一天的兩張專輯不會交錯")
    func albumsDoNotInterleave() {
        let a = Fixture.album("id-a", "A 專輯", date: "2020-01-01")
        let b = Fixture.album("id-b", "B 專輯", date: "2020-01-01")
        let entries = [
            Fixture.entry(b, Fixture.track("b1", number: 1)),
            Fixture.entry(a, Fixture.track("a2", number: 2)),
            Fixture.entry(b, Fixture.track("b2", number: 2)),
            Fixture.entry(a, Fixture.track("a1", number: 1)),
        ]
        #expect(ChronologicalSorter.sort(entries).map(\.track.id) == ["a1", "a2", "b1", "b2"])
    }

    @Test("同一首歌的不同版本全部保留，各自在自己的發行日")
    func keepsAllVersions() {
        let original = Fixture.album("orig", date: "2005-01-01")
        let remaster = Fixture.album("remaster", date: "2020-01-01")
        let between = Fixture.album("between", date: "2010-01-01")
        let song = { (id: String) in Track(id: id, name: "同一首歌", trackNumber: 1, artists: [Fixture.artist]) }
        let entries = [
            Fixture.entry(remaster, song("r")),
            Fixture.entry(between, Fixture.track("other", number: 1)),
            Fixture.entry(original, song("o")),
        ]
        #expect(ChronologicalSorter.sort(entries).map(\.track.id) == ["o", "other", "r"])
    }
}

@Suite("建立作品時間軸")
struct DiscographyBuilderTests {
    @Test("客串專輯只保留這位藝人參與的曲目")
    func appearsOnFiltersTracks() {
        let compilation = Fixture.album("comp", type: "compilation", date: "2012-01-01")
        let tracks = [
            Fixture.track("mine", number: 1, artists: [Fixture.other, Fixture.artist]),
            Fixture.track("theirs", number: 2, artists: [Fixture.other]),
        ]
        let entries = DiscographyBuilder.makeEntries(album: compilation, kind: .appearsOn, tracks: tracks, artistID: Fixture.artistID)
        #expect(entries.map(\.track.id) == ["mine"])
    }

    @Test("略過本機檔案和不能播放的曲目")
    func skipsUnplayable() {
        let album = Fixture.album("a", date: "2000-01-01")
        let tracks = [
            Track(id: "ok", name: "ok", trackNumber: 1),
            Track(id: "local", name: "local", trackNumber: 2, isLocal: true),
            Track(id: "blocked", name: "blocked", trackNumber: 3, isPlayable: false),
        ]
        let entries = DiscographyBuilder.makeEntries(album: album, kind: .album, tracks: tracks, artistID: Fixture.artistID)
        #expect(entries.map(\.track.id) == ["ok"])
    }

    @Test("依類型分類、過濾並排序")
    func buildsSortedTimeline() async throws {
        let album = Fixture.album("album", date: "2003-01-01")
        let single = Fixture.album("single", type: "single", date: "2001-01-01")
        let feat = Fixture.album("feat", type: "album", date: "2002-01-01")
        let catalog = FakeCatalog(
            ownAlbums: [album, single],
            appearsOn: [feat],
            tracks: [
                "album": [Fixture.track("album-1", number: 1)],
                "single": [Fixture.track("single-1", number: 1)],
                "feat": [Fixture.track("feat-1", number: 1), Fixture.track("feat-other", number: 2, artists: [Fixture.other])],
            ]
        )

        let all = try await DiscographyBuilder.build(artistID: Fixture.artistID, kinds: Set(ReleaseKind.allCases), api: catalog)
        #expect(all.map(\.track.id) == ["single-1", "feat-1", "album-1"])
        #expect(all.map(\.kind) == [.single, .appearsOn, .album])

        let albumsOnly = try await DiscographyBuilder.build(artistID: Fixture.artistID, kinds: [.album], api: catalog)
        #expect(albumsOnly.map(\.track.id) == ["album-1"])
    }
}
