import Foundation
import Testing
@testable import CoverDrop

struct AlbumDisplayNameCleaningTests {
    @Test("已有封面专辑会清洗格式版本年份分隔符并默认繁转简")
    func coveredAlbumNamesAreCleanedForDisplayAndSearch() {
        let album = makeAlbum(
            artist: "張學友",
            album: "1999 - [WAV] 愛與交響曲【港版】"
                + " [ape]",
            hasCover: true
        )

        let names = AlbumDisplayNameCleaning.displayNames(
            for: album,
            artistName: album.artistName,
            albumName: album.albumName
        )

        #expect(names.artistName == "张学友")
        #expect(names.albumName == "爱与交响曲")
        #expect(CoverSearchKeyword.make(
            artistName: names.artistName,
            albumName: names.albumName
        ) == "张学友 爱与交响曲")
    }

    @Test("无封面专辑也会先清洗展示名和搜索词")
    func missingCoverAlbumNamesAreCleanedForDisplayAndSearch() {
        let album = makeAlbum(
            artist: "張學友",
            album: "1999 - [WAV] 愛與交響曲【港版】",
            hasCover: false
        )

        let names = AlbumDisplayNameCleaning.displayNames(
            for: album,
            artistName: album.artistName,
            albumName: album.albumName
        )

        #expect(names.artistName == "张学友")
        #expect(names.albumName == "爱与交响曲")
        #expect(CoverSearchKeyword.make(
            artistName: names.artistName,
            albumName: names.albumName
        ) == "张学友 爱与交响曲")
    }

    @Test("稳定多数且被目录名佐证的标签会辅助确定展示名")
    func corroboratedMetadataMajorityImprovesDisplayNames() {
        let metadata = (0..<10).map { index in
            makeMetadata(
                album: index < 7 ? "I DO" : "错误标签 \(index)",
                artist: "S.H.E",
                albumArtist: "S.H.E"
            )
        }
        let album = makeAlbum(
            artist: "SHE合集【qobuz】",
            album: "2005-I...Do",
            hasCover: true,
            audioMetadata: metadata
        )

        let names = AlbumDisplayNameCleaning.displayNames(
            for: album,
            artistName: album.artistName,
            albumName: album.albumName
        )

        #expect(names.artistName == "S.H.E")
        #expect(names.albumName == "I DO")
    }

    @Test("标签低于多数阈值或与目录无关时回退目录清洗结果")
    func conflictingOrUncorroboratedMetadataFallsBackToFolderName() {
        let conflictingMetadata = (0..<10).map { index in
            makeMetadata(
                album: index < 6 ? "Wrong One" : "Wrong Two",
                artist: "错误歌手",
                albumArtist: "错误歌手"
            )
        }
        let album = makeAlbum(
            artist: "阿杜",
            album: "2002-Original Title",
            hasCover: true,
            audioMetadata: conflictingMetadata
        )

        let names = AlbumDisplayNameCleaning.displayNames(
            for: album,
            artistName: album.artistName,
            albumName: album.albumName
        )

        #expect(names.artistName == "阿杜")
        #expect(names.albumName == "Original Title")
    }

    @Test("占位标签和已有增强建议不会被音频标签覆盖")
    func placeholderMetadataAndSuggestionsAreNotOverridden() {
        let album = makeAlbum(
            artist: "阿杜",
            album: "2005-I...Do",
            hasCover: true,
            audioMetadata: Array(
                repeating: makeMetadata(
                    album: "CDImage",
                    artist: "阿杜",
                    albumArtist: "阿杜"
                ),
                count: 3
            )
        )

        let rawNames = AlbumDisplayNameCleaning.displayNames(
            for: album,
            artistName: album.artistName,
            albumName: album.albumName
        )
        let suggestedNames = AlbumDisplayNameCleaning.displayNames(
            for: album,
            artistName: "A-Do",
            albumName: "Custom Album"
        )

        #expect(rawNames.albumName == "I...Do")
        #expect(suggestedNames.artistName == "A-Do")
        #expect(suggestedNames.albumName == "Custom Album")
    }

    @Test("占位标签仍计入多数票分母，避免少数正常标签被放大")
    func placeholderMetadataStillCountsTowardMajorityDenominator() {
        let metadata = (0..<10).map { index in
            makeMetadata(
                album: index < 6 ? "CDImage" : "I DO",
                artist: "阿杜",
                albumArtist: "阿杜"
            )
        }
        let album = makeAlbum(
            artist: "阿杜",
            album: "2005-I...Do",
            hasCover: true,
            audioMetadata: metadata
        )

        let names = AlbumDisplayNameCleaning.displayNames(
            for: album,
            artistName: album.artistName,
            albumName: album.albumName
        )

        #expect(names.albumName == "I...Do")
    }

    @Test("大量重复标签不会按曲目反复执行名称清洗")
    func repeatedMetadataValuesStayWithinWallBuildBudget() {
        let repeatedMetadata = Array(
            repeating: makeMetadata(
                album: "I DO",
                artist: "S.H.E",
                albumArtist: "S.H.E"
            ),
            count: 5_000
        )
        let album = makeAlbum(
            artist: "SHE合集【qobuz】",
            album: "2005-I...Do",
            hasCover: true,
            audioMetadata: repeatedMetadata
        )

        let startedAt = Date()
        let names = AlbumDisplayNameCleaning.displayNames(
            for: album,
            artistName: album.artistName,
            albumName: album.albumName
        )
        let elapsed = Date().timeIntervalSince(startedAt)

        #expect(names.artistName == "S.H.E")
        #expect(names.albumName == "I DO")
        #expect(elapsed < 0.5, "重复标签展示名计算耗时 \(elapsed) 秒")
    }

    private func makeAlbum(
        artist: String,
        album: String,
        hasCover: Bool,
        audioMetadata: [AudioMetadata] = []
    ) -> AlbumScanRecord {
        let folderURL = URL(fileURLWithPath: "/tmp/\(artist)/\(album)", isDirectory: true)
        return AlbumScanRecord(
            folderURL: folderURL,
            artistName: artist,
            albumName: album,
            audioFiles: audioMetadata.enumerated().map { index, metadata in
                AudioFileRecord(
                    url: folderURL.appendingPathComponent("\(index + 1).flac"),
                    relativePath: "\(index + 1).flac",
                    format: "FLAC",
                    metadata: metadata,
                    readError: nil
                )
            },
            displayedCover: hasCover ? CoverCandidate(
                url: folderURL.appendingPathComponent("cover.jpg"),
                relativePath: "cover.jpg",
                namePriority: 0,
                depth: 0
            ) : nil,
            issues: []
        )
    }

    private func makeMetadata(
        album: String?,
        artist: String?,
        albumArtist: String?
    ) -> AudioMetadata {
        AudioMetadata(
            title: nil,
            artist: artist,
            albumArtist: albumArtist,
            album: album,
            discNumber: nil,
            trackNumber: nil,
            durationSeconds: nil
        )
    }
}
