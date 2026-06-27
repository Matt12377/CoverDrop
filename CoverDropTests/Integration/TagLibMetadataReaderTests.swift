import Foundation
import Testing
@testable import CoverDrop

struct TagLibMetadataReaderTests {
    @Test("TagLib 能读取真实 WAV 文件的音频时长")
    func readsRealWAVFile() async throws {
        try await withTemporaryDirectory { root in
            let audioURL = root.appendingPathComponent("一秒静音.wav")
            try makeOneSecondWAV().write(to: audioURL)

            let metadata = try await TagLibMetadataReader().readMetadata(at: audioURL)

            #expect(metadata.durationSeconds == 1)
            #expect(metadata.title == nil)
            #expect(metadata.album == nil)
        }
    }

    @Test("TagLib 对伪造音频返回可识别错误")
    func rejectsInvalidAudio() async throws {
        try await withTemporaryDirectory { root in
            let audioURL = root.appendingPathComponent("损坏.flac")
            try Data("不是音频".utf8).write(to: audioURL)

            await #expect(throws: (any Error).self) {
                try await TagLibMetadataReader().readMetadata(at: audioURL)
            }
        }
    }

    private func makeOneSecondWAV() -> Data {
        let sampleRate: UInt32 = 8_000
        let sampleCount = Int(sampleRate)
        var data = Data()
        data.appendASCII("RIFF")
        data.appendLittleEndian(UInt32(36 + sampleCount))
        data.appendASCII("WAVE")
        data.appendASCII("fmt ")
        data.appendLittleEndian(UInt32(16))
        data.appendLittleEndian(UInt16(1))
        data.appendLittleEndian(UInt16(1))
        data.appendLittleEndian(sampleRate)
        data.appendLittleEndian(sampleRate)
        data.appendLittleEndian(UInt16(1))
        data.appendLittleEndian(UInt16(8))
        data.appendASCII("data")
        data.appendLittleEndian(UInt32(sampleCount))
        data.append(Data(repeating: 128, count: sampleCount))
        return data
    }

    private func withTemporaryDirectory(
        _ operation: (URL) async throws -> Void
    ) async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("CoverDropTagLibTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        try await operation(root)
    }
}

private extension Data {
    mutating func appendASCII(_ string: String) {
        append(contentsOf: string.utf8)
    }

    mutating func appendLittleEndian<T: FixedWidthInteger>(_ value: T) {
        var littleEndian = value.littleEndian
        Swift.withUnsafeBytes(of: &littleEndian) { append(contentsOf: $0) }
    }
}
