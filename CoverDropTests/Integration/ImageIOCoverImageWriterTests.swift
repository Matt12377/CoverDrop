import Foundation
import ImageIO
import Testing
import UniformTypeIdentifiers
@testable import CoverDrop

struct ImageIOCoverImageWriterTests {
    @Test("PNG 拖入后写成 cover.jpg")
    func writesPNGAsCoverJPEG() async throws {
        try await withTemporaryDirectory { root in
            let sourceURL = root.appendingPathComponent("cover.png")
            try writeValidPNG(to: sourceURL)

            let writtenURL = try await ImageIOCoverImageWriter().writeCoverImage(
                from: sourceURL,
                toAlbumFolder: root
            )

            #expect(writtenURL.lastPathComponent == "cover.jpg")
            #expect(FileManager.default.fileExists(atPath: writtenURL.path))
            #expect(imageType(at: writtenURL) == UTType.jpeg.identifier)
        }
    }

    @Test("已有 cover.jpg 时会被替换")
    func replacesExistingCoverJPEG() async throws {
        try await withTemporaryDirectory { root in
            let sourceURL = root.appendingPathComponent("replacement.png")
            let destinationURL = root.appendingPathComponent("cover.jpg")
            let originalData = Data("旧封面".utf8)
            try writeValidPNG(to: sourceURL)
            try originalData.write(to: destinationURL)

            let writtenURL = try await ImageIOCoverImageWriter().writeCoverImage(
                from: sourceURL,
                toAlbumFolder: root
            )

            #expect(writtenURL == destinationURL)
            #expect(try Data(contentsOf: destinationURL) != originalData)
            #expect(imageType(at: destinationURL) == UTType.jpeg.identifier)
        }
    }

    @Test("非图片文件写入失败且不会生成或替换 cover.jpg")
    func rejectsNonImageWithoutChangingCover() async throws {
        try await withTemporaryDirectory { root in
            let textURL = root.appendingPathComponent("notes.txt")
            let existingCoverURL = root.appendingPathComponent("cover.jpg")
            let existingData = Data("已有封面".utf8)
            try Data("不是图片".utf8).write(to: textURL)
            try existingData.write(to: existingCoverURL)

            await #expect(throws: ImageIOCoverImageWriter.Failure.unreadableImage) {
                try await ImageIOCoverImageWriter().writeCoverImage(
                    from: textURL,
                    toAlbumFolder: root
                )
            }
            #expect(try Data(contentsOf: existingCoverURL) == existingData)

            try FileManager.default.removeItem(at: existingCoverURL)
            await #expect(throws: ImageIOCoverImageWriter.Failure.unreadableImage) {
                try await ImageIOCoverImageWriter().writeCoverImage(
                    from: textURL,
                    toAlbumFolder: root
                )
            }
            #expect(!FileManager.default.fileExists(atPath: existingCoverURL.path))
        }
    }

    private func writeValidPNG(to url: URL) throws {
        let png = try #require(Data(base64Encoded:
            "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mNk+A8AAQUBAScY42YAAAAASUVORK5CYII="
        ))
        try png.write(to: url)
    }

    private func imageType(at url: URL) -> String? {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil) else { return nil }
        return CGImageSourceGetType(source) as String?
    }

    private func withTemporaryDirectory(
        _ operation: (URL) async throws -> Void
    ) async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("CoverDropWriterTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        try await operation(root)
    }
}
