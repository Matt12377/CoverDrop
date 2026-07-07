import Foundation
import CoreGraphics
import ImageIO
import Testing
import UniformTypeIdentifiers
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

    @Test("多张非标准图片会选出最像封面的图片")
    func multipleArbitrarilyNamedImagesChooseLikelyCover() async throws {
        try await withTemporaryDirectory { root in
            try writeValidPNG(to: root.appendingPathComponent("扫描图片 001.png"), width: 300, height: 300)
            try writeValidPNG(to: root.appendingPathComponent("扫描图片 002.png"), width: 600, height: 600)

            let result = try await ImageIOCoverDetector().detectCover(in: root)

            #expect(result.selected?.relativePath == "扫描图片 002.png")
        }
    }

    @Test("多张非标准图片中正方形大图优先于横向和纵向图")
    func squareLargeImageBeatsLandscapeAndPortraitImages() async throws {
        try await withTemporaryDirectory { root in
            try writeValidPNG(to: root.appendingPathComponent("wide.png"), width: 1600, height: 900)
            try writeValidPNG(to: root.appendingPathComponent("tall.png"), width: 900, height: 1600)
            try writeValidPNG(to: root.appendingPathComponent("album scan.png"), width: 900, height: 900)

            let result = try await ImageIOCoverDetector().detectCover(in: root)

            #expect(result.selected?.relativePath == "album scan.png")
        }
    }

    @Test("根目录非标准图片优先于子目录扫描图")
    func rootImageBeatsNestedScanImage() async throws {
        try await withTemporaryDirectory { root in
            try writeValidPNG(to: root.appendingPathComponent("image.png"), width: 700, height: 700)
            try writeValidPNG(to: root.appendingPathComponent("Scans/album scan.png"), width: 1400, height: 1400)

            let result = try await ImageIOCoverDetector().detectCover(in: root)

            #expect(result.selected?.relativePath == "image.png")
        }
    }

    @Test("负向名称不会优先于普通正方形候选")
    func negativeCoverLikeNamesArePenalized() async throws {
        try await withTemporaryDirectory { root in
            try writeValidPNG(to: root.appendingPathComponent("封底.png"), width: 1200, height: 1200)
            try writeValidPNG(to: root.appendingPathComponent("disc.png"), width: 1200, height: 1200)
            try writeValidPNG(to: root.appendingPathComponent("image.png"), width: 1000, height: 1000)

            let result = try await ImageIOCoverDetector().detectCover(in: root)

            #expect(result.selected?.relativePath == "image.png")
        }
    }

    @Test("标准命名图片仍然优先于启发式候选")
    func knownCoverNameBeatsHeuristicCandidate() async throws {
        try await withTemporaryDirectory { root in
            try writeValidPNG(to: root.appendingPathComponent("cover.png"), width: 300, height: 500)
            try writeValidPNG(to: root.appendingPathComponent("album artwork.png"), width: 1600, height: 1600)

            let result = try await ImageIOCoverDetector().detectCover(in: root)

            #expect(result.selected?.relativePath == "cover.png")
            #expect(result.invalidNamedPaths.isEmpty)
        }
    }

    @Test("损坏标准命名图片会被报告且有效非标准图片可被选中")
    func invalidNamedCoverIsReportedWhileValidArbitraryImageCanBeSelected() async throws {
        try await withTemporaryDirectory { root in
            try Data("不是图片".utf8).write(to: root.appendingPathComponent("cover.jpg"))
            try writeValidPNG(to: root.appendingPathComponent("album scan.png"), width: 800, height: 800)

            let result = try await ImageIOCoverDetector().detectCover(in: root)

            #expect(result.selected?.relativePath == "album scan.png")
            #expect(result.invalidNamedPaths == ["cover.jpg"])
        }
    }

    private func writeValidPNG(to url: URL, width: Int = 1, height: Int = 1) throws {
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        let colorSpace = CGColorSpaceCreateDeviceRGB()
        let bitmapInfo = CGImageAlphaInfo.premultipliedLast.rawValue
        let context = try #require(CGContext(
            data: nil,
            width: width,
            height: height,
            bitsPerComponent: 8,
            bytesPerRow: 0,
            space: colorSpace,
            bitmapInfo: bitmapInfo
        ))
        context.setFillColor(red: 0.2, green: 0.3, blue: 0.4, alpha: 1)
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        let image = try #require(context.makeImage())
        let destination = try #require(CGImageDestinationCreateWithURL(
            url as CFURL,
            UTType.png.identifier as CFString,
            1,
            nil
        ))
        CGImageDestinationAddImage(destination, image, nil)
        try #require(CGImageDestinationFinalize(destination))
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
