import Testing
@testable import CoverDrop

struct LibraryScanProgressTests {
    @Test("扫描进度同时说明专辑和当前音频完成量")
    func completionDescriptionIncludesAlbumAndFileCounts() {
        let progress = LibraryScanProgress(
            phase: .readingMetadata,
            targetPath: "/音乐/歌手/专辑/03.flac",
            completedAlbums: 12,
            totalAlbums: 100,
            completedFilesInAlbum: 2,
            totalFilesInAlbum: 10
        )

        #expect(progress.phase.displayName == "正在读取音频标签")
        #expect(progress.completedDescription == "已完成 12 / 100 张专辑 · 当前专辑 2 / 10 个音频")
        #expect(progress.albumProgressFraction == 0.12)
    }

    @Test("分析目录阶段使用不确定进度")
    func discoveryUsesIndeterminateProgress() {
        let progress = LibraryScanProgress(
            phase: .discoveringAlbums,
            targetPath: "/音乐",
            completedAlbums: 0,
            totalAlbums: nil,
            completedFilesInAlbum: nil,
            totalFilesInAlbum: nil
        )

        #expect(progress.completedDescription == "正在建立专辑清单…")
        #expect(progress.albumProgressFraction == nil)
    }
}
