import Foundation
import Testing
@testable import CoverDrop

struct AlbumAudioTrackDisplayItemTests {
    @Test("有标签标题时显示标题")
    func usesMetadataTitleWhenAvailable() {
        let item = AlbumAudioTrackDisplayItem(
            audioFile: audioFile(
                relativePath: "Disc 1/01 - fallback.flac",
                metadata: metadata(title: "Intro")
            )
        )

        #expect(item.title == "Intro")
    }

    @Test("没有标签标题时回退到文件名")
    func fallsBackToLastPathComponentWhenTitleIsMissing() {
        let item = AlbumAudioTrackDisplayItem(
            audioFile: audioFile(
                relativePath: "CD2/Sub Folder/02 - fallback.wav",
                metadata: metadata(title: nil)
            )
        )

        #expect(item.title == "02 - fallback.wav")
    }

    @Test("有碟号和曲序时格式化为可读序号")
    func formatsDiscAndTrackNumber() {
        let item = AlbumAudioTrackDisplayItem(
            audioFile: audioFile(
                metadata: metadata(discNumber: 2, trackNumber: 3)
            )
        )

        #expect(item.sequenceText == "2-03")
    }

    @Test("有时长时格式化为分秒或时分秒")
    func formatsDuration() {
        let shortItem = AlbumAudioTrackDisplayItem(
            audioFile: audioFile(metadata: metadata(durationSeconds: 185))
        )
        let longItem = AlbumAudioTrackDisplayItem(
            audioFile: audioFile(metadata: metadata(durationSeconds: 3725))
        )

        #expect(shortItem.durationText == "3:05")
        #expect(longItem.durationText == "1:02:05")
    }

    @Test("有读取错误时标记异常")
    func marksReadError() {
        let item = AlbumAudioTrackDisplayItem(
            audioFile: audioFile(readError: "无法读取标签")
        )

        #expect(item.hasReadError)
        #expect(item.readError == "无法读取标签")
    }

    private func audioFile(
        relativePath: String = "01 - track.flac",
        format: String = "flac",
        metadata: AudioMetadata? = nil,
        readError: String? = nil
    ) -> AudioFileRecord {
        AudioFileRecord(
            url: URL(fileURLWithPath: "/tmp/Album/\(relativePath)"),
            relativePath: relativePath,
            format: format,
            metadata: metadata ?? self.metadata(),
            readError: readError
        )
    }

    private func metadata(
        title: String? = "Track",
        discNumber: Int? = nil,
        trackNumber: Int? = nil,
        durationSeconds: Int? = nil
    ) -> AudioMetadata {
        AudioMetadata(
            title: title,
            artist: nil,
            albumArtist: nil,
            album: nil,
            discNumber: discNumber,
            trackNumber: trackNumber,
            durationSeconds: durationSeconds
        )
    }
}
