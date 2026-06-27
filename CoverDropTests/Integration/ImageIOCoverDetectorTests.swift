import Foundation
import Testing
@testable import CoverDrop

struct ImageIOCoverDetectorTests {
    @Test("根目录常见封面优先于多碟子目录封面")
    func rootCoverHasPriority() async throws {
        try await withTemporaryDirectory { root in
            try writeValidPNG(to: root.appendingPathComponent("cover.png"))
            try writeValidPNG(to: root.appendingPathComponent("CD1/folder.png"))

            let result = try await ImageIOCoverDetector().detectCover(in: root)

            #expect(result.selected?.relativePath == "cover.png")
            #expect(result.invalidNamedPaths.isEmpty)
        }
    }

    @Test("同层封面按 cover、folder、front 的顺序选择")
    func commonNamePriorityIsStable() async throws {
        try await withTemporaryDirectory { root in
            try writeValidPNG(to: root.appendingPathComponent("front.png"))
            try writeValidPNG(to: root.appendingPathComponent("folder.png"))

            let result = try await ImageIOCoverDetector().detectCover(in: root)

            #expect(result.selected?.relativePath == "folder.png")
        }
    }

    @Test("损坏的常见封面会被报告但不会当作封面")
    func invalidNamedCoverIsReported() async throws {
        try await withTemporaryDirectory { root in
            try Data("不是图片".utf8).write(to: root.appendingPathComponent("cover.jpg"))

            let result = try await ImageIOCoverDetector().detectCover(in: root)

            #expect(result.selected == nil)
            #expect(result.invalidNamedPaths == ["cover.jpg"])
        }
    }

    @Test("专辑树只有一张图片时不限制文件名")
    func singleArbitrarilyNamedImageIsCover() async throws {
        try await withTemporaryDirectory { root in
            try writeValidPNG(to: root.appendingPathComponent("CD1/扫描图片 001.png"))

            let result = try await ImageIOCoverDetector().detectCover(in: root)

            #expect(result.selected?.relativePath == "CD1/扫描图片 001.png")
        }
    }

    @Test("选中的图片文件会生成应用缓存预览")
    func selectedImageFileGetsCachedPreview() async throws {
        try await withTemporaryDirectory { root in
            let sourceURL = root.appendingPathComponent("cover.png")
            try writeValidPNG(to: sourceURL)

            let result = try await ImageIOCoverDetector().detectCover(in: root)
            let selected = try #require(result.selected)

            #expect(isSameFileURL(selected.url, sourceURL))
            #expect(selected.previewURL != nil)
            #expect(selected.displayURL == selected.previewURL)
            #expect(FileManager.default.fileExists(atPath: try #require(selected.previewURL).path))
        }
    }

    @Test("并发检测同一张图片时复用已生成的缓存预览")
    func concurrentPreviewCachingReusesExistingFile() async throws {
        try await withTemporaryDirectory { root in
            let sourceURL = root.appendingPathComponent("cover.png")
            try writeValidPNG(to: sourceURL)

            let results = try await withThrowingTaskGroup(of: CoverDetectionResult.self) { group in
                for _ in 0..<12 {
                    group.addTask {
                        try await ImageIOCoverDetector().detectCover(in: root)
                    }
                }

                var values: [CoverDetectionResult] = []
                for try await result in group {
                    values.append(result)
                }
                return values
            }

            #expect(results.count == 12)
            for result in results {
                let selected = try #require(result.selected)
                let previewURL = try #require(selected.previewURL)
                #expect(isSameFileURL(selected.url, sourceURL))
                #expect(FileManager.default.fileExists(atPath: previewURL.path))
            }
        }
    }

    @Test("多张任意命名图片不会被擅自选为封面")
    func multipleArbitrarilyNamedImagesNeedKnownCoverName() async throws {
        try await withTemporaryDirectory { root in
            try writeValidPNG(to: root.appendingPathComponent("扫描图片 001.png"))
            try writeValidPNG(to: root.appendingPathComponent("扫描图片 002.png"))

            let result = try await ImageIOCoverDetector().detectCover(in: root)

            #expect(result.selected == nil)
        }
    }

    private func writeValidPNG(to url: URL) throws {
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        let png = try #require(Data(base64Encoded:
            "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mNk+A8AAQUBAScY42YAAAAASUVORK5CYII="
        ))
        try png.write(to: url)
    }

    private func isSameFileURL(_ lhs: URL, _ rhs: URL) -> Bool {
        lhs.standardizedFileURL.resolvingSymlinksInPath().path
            == rhs.standardizedFileURL.resolvingSymlinksInPath().path
    }

    private func withTemporaryDirectory(
        _ operation: (URL) async throws -> Void
    ) async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("CoverDropCoverTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        try await operation(root)
    }
}
