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

    @Test("无封面专辑不做展示名清洗")
    func missingCoverAlbumNamesAreNotCleaned() {
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

        #expect(names.artistName == "張學友")
        #expect(names.albumName == "1999 - [WAV] 愛與交響曲【港版】")
    }

    private func makeAlbum(
        artist: String,
        album: String,
        hasCover: Bool
    ) -> AlbumScanRecord {
        let folderURL = URL(fileURLWithPath: "/tmp/\(artist)/\(album)", isDirectory: true)
        return AlbumScanRecord(
            folderURL: folderURL,
            artistName: artist,
            albumName: album,
            audioFiles: [],
            displayedCover: hasCover ? CoverCandidate(
                url: folderURL.appendingPathComponent("cover.jpg"),
                relativePath: "cover.jpg",
                namePriority: 0,
                depth: 0
            ) : nil,
            issues: []
        )
    }
}
