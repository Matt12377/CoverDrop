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

    @Test("需确认保留为专辑状态但不作为封面墙分类")
    func needsAttentionStateIsNotCoverWallFilter() {
        let attentionAlbum = album("整轨专辑", cover: true, issues: [.singleFileNeedsConfirmation(hasCue: true)])

        #expect(attentionAlbum.needsAttention)
        #expect(!AlbumScanResultFilter.allCases.map(\.rawValue).contains("needsAttention"))
    }

    @Test("未分轨筛选只显示带 CUE 的单文件整轨专辑")
    func singleFileUnsplitFilterOnlyReturnsSingleImageCueAlbums() {
        let result = LibraryScanResult(
            albums: [
                album("已分轨专辑", cover: true),
                album("单文件发行", cover: true, issues: [.singleFileNeedsConfirmation(hasCue: false)]),
                album("未分轨整轨", cover: true, issues: [.singleFileNeedsConfirmation(hasCue: true)])
            ],
            looseAudioPaths: ["根目录散曲.dsf"]
        )

        #expect(AlbumScanResultFilter.allCases.contains(.singleFileUnsplit))
        #expect(AlbumScanResultFilter.singleFileUnsplit.displayName == "未分轨")
        #expect(AlbumScanResultFiltering.albums(
            in: result,
            filter: .singleFileUnsplit,
            query: ""
        ).map(\.albumName) == ["未分轨整轨"])
        #expect(AlbumScanResultFiltering.looseAudioPaths(
            in: result,
            filter: .singleFileUnsplit,
            query: ""
        ).isEmpty)
    }

    @Test("标签异常筛选只显示音频标签读取失败专辑")
    func metadataReadFailedFilterOnlyReturnsMetadataFailedAlbums() {
        let result = LibraryScanResult(
            albums: [
                album("普通专辑", cover: true),
                album("未分轨整轨", cover: true, issues: [.singleFileNeedsConfirmation(hasCue: true)]),
                album("标签异常专辑", cover: true, issues: [.metadataReadFailed(paths: ["01.flac"])])
            ],
            looseAudioPaths: ["根目录散曲.dsf"]
        )

        #expect(AlbumScanResultFilter.allCases.contains(.metadataReadFailed))
        #expect(AlbumScanResultFilter.metadataReadFailed.displayName == "标签异常")
        #expect(AlbumScanResultFiltering.albums(
            in: result,
            filter: .metadataReadFailed,
            query: ""
        ).map(\.albumName) == ["标签异常专辑"])
        #expect(AlbumScanResultFiltering.looseAudioPaths(
            in: result,
            filter: .metadataReadFailed,
            query: ""
        ).isEmpty)
    }

    @Test("track 音轨筛选只显示 track 命名音轨专辑")
    func trackNamedAudioFilesFilterOnlyReturnsTrackNamedAlbums() {
        let result = LibraryScanResult(
            albums: [
                album("普通专辑", cover: true),
                album("标签异常专辑", cover: true, issues: [.metadataReadFailed(paths: ["01.flac"])]),
                album("track 音轨专辑", cover: true, issues: [.trackNamedAudioFiles(paths: ["01 第一首/track.flac"])])
            ],
            looseAudioPaths: ["根目录散曲.dsf"]
        )

        #expect(AlbumScanResultFilter.allCases.contains(.trackNamedAudioFiles))
        #expect(AlbumScanResultFilter.trackNamedAudioFiles.displayName == "track音轨")
        #expect(AlbumScanResultFiltering.albums(
            in: result,
            filter: .trackNamedAudioFiles,
            query: ""
        ).map(\.albumName) == ["track 音轨专辑"])
        #expect(AlbumScanResultFiltering.looseAudioPaths(
            in: result,
            filter: .trackNamedAudioFiles,
            query: ""
        ).isEmpty)
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
        #expect(AlbumScanResultFiltering.looseAudioPaths(in: result, filter: .singleFileUnsplit, query: "").isEmpty)
        #expect(AlbumScanResultFiltering.looseAudioPaths(in: result, filter: .metadataReadFailed, query: "").isEmpty)
        #expect(AlbumScanResultFiltering.looseAudioPaths(in: result, filter: .trackNamedAudioFiles, query: "").isEmpty)
        #expect(AlbumScanResultFiltering.looseAudioPaths(in: result, filter: .looseAudio, query: "") == ["根目录散曲.dsf"])
    }

    @Test("解析失败筛选只显示 Ollama 失败专辑")
    func nameEnhancementFailedFilterOnlyReturnsFailedAlbums() {
        let failedAlbum = album("解析失败专辑", cover: false)
        let normalAlbum = album("正常专辑", cover: false)
        let result = LibraryScanResult(
            albums: [failedAlbum, normalAlbum],
            looseAudioPaths: ["根目录散曲.dsf"]
        )

        #expect(AlbumScanResultFilter.allCases.contains(.nameEnhancementFailed))
        #expect(AlbumScanResultFilter.nameEnhancementFailed.displayName == "解析失败")
        #expect(AlbumScanResultFiltering.albums(
            in: result,
            filter: .nameEnhancementFailed,
            query: "",
            failedAlbumIDs: [failedAlbum.id]
        ).map(\.albumName) == ["解析失败专辑"])
        #expect(AlbumScanResultFiltering.looseAudioPaths(
            in: result,
            filter: .nameEnhancementFailed,
            query: ""
        ).isEmpty)
    }

    @Test("增强后的歌手和专辑名也会参与搜索筛选")
    func queryMatchesEnhancedDisplayNames() {
        let result = LibraryScanResult(
            albums: [album("原始专辑", artist: "原始歌手", cover: true)],
            looseAudioPaths: []
        )

        let filtered = AlbumScanResultFiltering.albums(
            in: result,
            filter: .all,
            query: "增强后专辑",
            displayNames: { _ in
                (artistName: "增强后歌手", albumName: "增强后专辑")
            }
        )

        #expect(filtered.map(\.albumName) == ["原始专辑"])
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
