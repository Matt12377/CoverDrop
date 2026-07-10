import Foundation
import Testing
@testable import CoverDrop

struct UnsplitAlbumSelectionTests {
    @Test("未分轨选择支持选择取消和全选")
    func selectionTogglesAndSelectsAllUnsplitAlbums() {
        let cueAlbum = makeAlbum(index: 1, hasCue: true)
        let noCueAlbum = makeAlbum(index: 2, hasCue: false)
        var selection = UnsplitAlbumSelection()

        selection.toggle(cueAlbum.id)
        #expect(selection.selectedAlbumIDs == [cueAlbum.id])

        selection.toggle(cueAlbum.id)
        #expect(selection.selectedAlbumIDs.isEmpty)

        selection.selectAllSplitCandidates(in: [cueAlbum, noCueAlbum])
        #expect(selection.selectedAlbumIDs == [cueAlbum.id])

        selection.clear()
        #expect(selection.selectedAlbumIDs.isEmpty)
    }

    @Test("只有带 CUE 的单整轨专辑可用 XLD 分轨")
    func splitCandidatesRequireSingleAudioAndCueIssue() {
        let candidate = makeAlbum(index: 1, hasCue: true, audioCount: 1)
        let noCue = makeAlbum(index: 2, hasCue: false, audioCount: 1)
        let multiAudio = makeAlbum(index: 3, hasCue: true, audioCount: 2)

        #expect(UnsplitAlbumSelection.canSplitWithXLD(candidate))
        #expect(!UnsplitAlbumSelection.canSplitWithXLD(noCue))
        #expect(!UnsplitAlbumSelection.canSplitWithXLD(multiAudio))
    }

    private func makeAlbum(
        index: Int,
        hasCue: Bool,
        audioCount: Int = 1
    ) -> AlbumScanRecord {
        let folderURL = URL(fileURLWithPath: "/tmp/歌手/专辑 \(index)", isDirectory: true)
        return AlbumScanRecord(
            folderURL: folderURL,
            artistName: "歌手",
            albumName: "专辑 \(index)",
            audioFiles: (0..<audioCount).map { audioIndex in
                AudioFileRecord(
                    url: folderURL.appendingPathComponent("\(audioIndex + 1).flac"),
                    relativePath: "\(audioIndex + 1).flac",
                    format: "flac",
                    metadata: nil,
                    readError: nil
                )
            },
            cueSheets: hasCue ? [
                CueSheetRecord(
                    url: folderURL.appendingPathComponent("album.cue"),
                    relativePath: "album.cue"
                )
            ] : [],
            displayedCover: nil,
            issues: [.singleFileNeedsConfirmation(hasCue: hasCue)]
        )
    }
}
