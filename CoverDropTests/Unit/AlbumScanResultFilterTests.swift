import Foundation
import Testing
@testable import CoverDrop

struct AlbumScanResultFilterTests {
    @Test("按封面状态筛选专辑")
    func filtersAlbumsByCoverState() {
        let result = LibraryScanResult(
            albums: [
                album("七里香", cover: true),
                album("缺失封面", cover: false)
            ],
            looseAudioPaths: []
        )

        #expect(AlbumScanResultFiltering.albums(in: result, filter: .withCover, query: "").map(\.albumName) == ["七里香"])
        #expect(AlbumScanResultFiltering.albums(in: result, filter: .missingCover, query: "").map(\.albumName) == ["缺失封面"])
    }

    @Test("按需要确认筛选专辑")
    func filtersAlbumsNeedingAttention() {
        let result = LibraryScanResult(
            albums: [
                album("普通专辑", cover: true),
                album("整轨专辑", cover: true, issues: [.singleFileNeedsConfirmation(hasCue: true)])
            ],
            looseAudioPaths: []
        )

        #expect(AlbumScanResultFiltering.albums(in: result, filter: .needsAttention, query: "").map(\.albumName) == ["整轨专辑"])
    }

    @Test("按关键词匹配歌手专辑和路径")
    func filtersByQuery() {
        let result = LibraryScanResult(
            albums: [
                album("狂野之城", artist: "郭富城", cover: true),
                album("七里香", artist: "周杰伦", cover: true)
            ],
            looseAudioPaths: ["郭富城/散曲.wav", "周杰伦/演唱会.wav"]
        )

        #expect(AlbumScanResultFiltering.albums(in: result, filter: .all, query: "郭富城").map(\.albumName) == ["狂野之城"])
        #expect(AlbumScanResultFiltering.looseAudioPaths(in: result, filter: .looseAudio, query: "周杰伦") == ["周杰伦/演唱会.wav"])
    }

    @Test("散落音频筛选不混入专辑")
    func looseAudioFilterOnlyReturnsLooseAudio() {
        let result = LibraryScanResult(
            albums: [album("七里香", cover: true)],
            looseAudioPaths: ["根目录散曲.dsf"]
        )

        #expect(AlbumScanResultFiltering.albums(in: result, filter: .looseAudio, query: "").isEmpty)
        #expect(AlbumScanResultFiltering.looseAudioPaths(in: result, filter: .looseAudio, query: "") == ["根目录散曲.dsf"])
    }

    @Test("散落音频只在散落音频分类显示")
    func looseAudioOnlyAppearsInLooseAudioFilter() {
        let result = LibraryScanResult(
            albums: [album("七里香", cover: true)],
            looseAudioPaths: ["根目录散曲.dsf"]
        )

        #expect(AlbumScanResultFiltering.looseAudioPaths(in: result, filter: .all, query: "").isEmpty)
        #expect(AlbumScanResultFiltering.looseAudioPaths(in: result, filter: .withCover, query: "").isEmpty)
        #expect(AlbumScanResultFiltering.looseAudioPaths(in: result, filter: .missingCover, query: "").isEmpty)
        #expect(AlbumScanResultFiltering.looseAudioPaths(in: result, filter: .needsAttention, query: "").isEmpty)
        #expect(AlbumScanResultFiltering.looseAudioPaths(in: result, filter: .looseAudio, query: "") == ["根目录散曲.dsf"])
    }

    private func album(
        _ name: String,
        artist: String = "测试歌手",
        cover: Bool,
        issues: [AlbumScanIssue] = []
    ) -> AlbumScanRecord {
        let folderURL = URL(fileURLWithPath: "/tmp/\(artist)/\(name)", isDirectory: true)
        return AlbumScanRecord(
            folderURL: folderURL,
            artistName: artist,
            albumName: name,
            audioFiles: [],
            displayedCover: cover ? CoverCandidate(
                url: folderURL.appendingPathComponent("cover.jpg"),
                relativePath: "cover.jpg",
                namePriority: 0,
                depth: 0
            ) : nil,
            issues: issues
        )
    }
}
