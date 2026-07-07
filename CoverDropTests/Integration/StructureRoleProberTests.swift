import Foundation
import Testing
@testable import CoverDrop

struct StructureRoleProberTests {
    @Test("直属音频建议为单张专辑")
    func directAudioSuggestsAlbum() async throws {
        try await withTemporaryDirectory { root in
            try Data().write(to: root.appendingPathComponent("整轨.wav"))

            let suggestion = try await StructureRoleProber().suggestRole(for: root)

            #expect(suggestion.role == .album)
        }
    }

    @Test("歌手的直接子目录建议为歌手目录")
    func directAlbumFoldersSuggestArtist() async throws {
        try await withTemporaryDirectory { root in
            let album = root.appendingPathComponent("叶惠美", isDirectory: true)
            try FileManager.default.createDirectory(at: album, withIntermediateDirectories: true)
            try Data().write(to: album.appendingPathComponent("01.flac"))

            let suggestion = try await StructureRoleProber().suggestRole(for: root)

            #expect(suggestion.role == .artist)
        }
    }

    @Test("歌手和专辑两层结构建议为音乐库")
    func twoLevelsSuggestLibrary() async throws {
        try await withTemporaryDirectory { root in
            let album = root
                .appendingPathComponent("周杰伦", isDirectory: true)
                .appendingPathComponent("七里香", isDirectory: true)
            try FileManager.default.createDirectory(at: album, withIntermediateDirectories: true)
            try Data().write(to: album.appendingPathComponent("01.ape"))

            let suggestion = try await StructureRoleProber().suggestRole(for: root)

            #expect(suggestion.role == .library)
        }
    }

    @Test("CD子目录建议合并为单张专辑")
    func discFoldersSuggestAlbum() async throws {
        try await withTemporaryDirectory { root in
            let disc = root.appendingPathComponent("CD1", isDirectory: true)
            try FileManager.default.createDirectory(at: disc, withIntermediateDirectories: true)
            try Data().write(to: disc.appendingPathComponent("01.dsf"))

            let suggestion = try await StructureRoleProber().suggestRole(for: root)

            #expect(suggestion.role == .album)
        }
    }

    @Test("空文件夹给出明确错误")
    func emptyFolderIsRejected() async throws {
        try await withTemporaryDirectory { root in
            await #expect(throws: LibraryImportError.emptyDirectory) {
                try await StructureRoleProber().suggestRole(for: root)
            }
        }
    }

    @Test("扩展名像音频的文件夹不会被当成音频")
    func audioExtensionDirectoryIsNotAudioFile() async throws {
        try await withTemporaryDirectory { root in
            try FileManager.default.createDirectory(
                at: root.appendingPathComponent("不是音频.flac", isDirectory: true),
                withIntermediateDirectories: true
            )

            await #expect(throws: LibraryImportError.noAudioFound) {
                try await StructureRoleProber().suggestRole(for: root)
            }
        }
    }

    private func withTemporaryDirectory(
        _ operation: (URL) async throws -> Void
    ) async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("CoverDropTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        try await operation(root)
    }
}
