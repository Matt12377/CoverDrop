import AppKit
import Foundation
import ImageIO
import Testing
import UniformTypeIdentifiers
@testable import CoverDrop

struct CoverPreviewCacheTests {
    @Test("同一路径图片变化后不会返回旧缩略图")
    func cachedImageChangesWhenFileIdentityChanges() async throws {
        try await withTemporaryDirectory { root in
            let imageURL = root.appendingPathComponent("cover.png")
            try pngData(width: 1, height: 1, color: .red).write(to: imageURL)
            CoverPreviewCache.clearMemoryCache()

            let firstImage = try #require(CoverPreviewCache.cachedImage(for: imageURL, maxPixelSize: 336))

            try pngData(width: 3, height: 3, color: .blue).write(to: imageURL)
            try setModificationDate(Date(timeIntervalSince1970: 4_000), for: imageURL)
            let secondImage = try #require(CoverPreviewCache.cachedImage(for: imageURL, maxPixelSize: 336))

            #expect(firstImage !== secondImage)
            #expect(secondImage.size.width == 3)
            #expect(secondImage.size.height == 3)
        }
    }

    @Test("同一路径图片变化后预览 URL 缓存会重新生成")
    func cachedPreviewURLChangesWhenFileIdentityChanges() async throws {
        try await withTemporaryDirectory { root in
            let imageURL = root.appendingPathComponent("cover.png")
            try pngData(width: 1, height: 1, color: .red).write(to: imageURL)
            CoverPreviewCache.clearMemoryCache()

            let firstPreviewURL = try #require(CoverPreviewCache.cachedPreviewURL(for: imageURL))

            try pngData(width: 4, height: 4, color: .blue).write(to: imageURL)
            try setModificationDate(Date(timeIntervalSince1970: 5_000), for: imageURL)
            let secondPreviewURL = try #require(CoverPreviewCache.cachedPreviewURL(for: imageURL))

            #expect(firstPreviewURL != secondPreviewURL)
            #expect(FileManager.default.fileExists(atPath: secondPreviewURL.path))
        }
    }

    @Test("任意 UI 尺寸的封面缩略图都可以按路径失效")
    func invalidateImageCacheRemovesAllTrackedSizes() async throws {
        try await withTemporaryDirectory { root in
            let imageURL = root.appendingPathComponent("cover.png")
            try pngData(width: 2, height: 2, color: .green).write(to: imageURL)
            CoverPreviewCache.clearMemoryCache()

            let first336 = try #require(CoverPreviewCache.cachedImage(for: imageURL, maxPixelSize: 336))
            let first600 = try #require(CoverPreviewCache.cachedImage(for: imageURL, maxPixelSize: 600))

            CoverPreviewCache.invalidateImageCache(for: imageURL)

            let second336 = try #require(CoverPreviewCache.cachedImage(for: imageURL, maxPixelSize: 336))
            let second600 = try #require(CoverPreviewCache.cachedImage(for: imageURL, maxPixelSize: 600))

            #expect(first336 !== second336)
            #expect(first600 !== second600)
        }
    }

    @Test("内部保存封面后会刷新预览并失效旧缩略图")
    func refreshedPreviewURLForUpdatedCoverInvalidatesSourceAndPreviewImages() async throws {
        try await withTemporaryDirectory { root in
            let imageURL = root.appendingPathComponent("cover.png")
            let redData = try pngData(width: 3, height: 3, color: .red)
            let blueData = try pngData(width: 3, height: 3, color: .blue)
            try redData.write(to: imageURL)
            try setModificationDate(Date(timeIntervalSince1970: 6_000), for: imageURL)
            CoverPreviewCache.clearMemoryCache()

            let firstPreviewURL = try #require(CoverPreviewCache.refreshedPreviewURLForUpdatedCover(imageURL))
            let firstSourceImage = try #require(CoverPreviewCache.cachedImage(for: imageURL, maxPixelSize: 336))
            let firstPreviewImage = try #require(CoverPreviewCache.cachedImage(for: firstPreviewURL, maxPixelSize: 336))
            let firstPreviewData = try Data(contentsOf: firstPreviewURL)

            try blueData.write(to: imageURL)
            try setModificationDate(Date(timeIntervalSince1970: 6_000), for: imageURL)

            let secondPreviewURL = try #require(CoverPreviewCache.refreshedPreviewURLForUpdatedCover(imageURL))
            let secondSourceImage = try #require(CoverPreviewCache.cachedImage(for: imageURL, maxPixelSize: 336))
            let secondPreviewImage = try #require(CoverPreviewCache.cachedImage(for: secondPreviewURL, maxPixelSize: 336))
            let secondPreviewData = try Data(contentsOf: secondPreviewURL)

            #expect(firstSourceImage !== secondSourceImage)
            #expect(firstPreviewImage !== secondPreviewImage)
            #expect(firstPreviewData != secondPreviewData)
        }
    }

    private func pngData(width: Int, height: Int, color: NSColor) throws -> Data {
        let rgbColor = try #require(color.usingColorSpace(.deviceRGB))
        let red = UInt8((rgbColor.redComponent * 255).rounded())
        let green = UInt8((rgbColor.greenComponent * 255).rounded())
        let blue = UInt8((rgbColor.blueComponent * 255).rounded())
        let alpha = UInt8((rgbColor.alphaComponent * 255).rounded())
        let pixel = [red, green, blue, alpha]
        let pixels = Data(Array(repeating: pixel, count: width * height).flatMap { $0 })
        let provider = try #require(CGDataProvider(data: pixels as CFData))
        let image = try #require(CGImage(
            width: width,
            height: height,
            bitsPerComponent: 8,
            bitsPerPixel: 32,
            bytesPerRow: width * 4,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue),
            provider: provider,
            decode: nil,
            shouldInterpolate: false,
            intent: .defaultIntent
        ))
        let output = NSMutableData()
        let destination = try #require(CGImageDestinationCreateWithData(
            output,
            UTType.png.identifier as CFString,
            1,
            nil
        ))
        CGImageDestinationAddImage(destination, image, nil)
        try #require(CGImageDestinationFinalize(destination))
        return output as Data
    }
}

private func setModificationDate(_ date: Date, for url: URL) throws {
    try FileManager.default.setAttributes(
        [.modificationDate: date],
        ofItemAtPath: url.path
    )
}

private func withTemporaryDirectory(
    _ body: (URL) async throws -> Void
) async throws {
    let url = FileManager.default.temporaryDirectory
        .appendingPathComponent("CoverDropTests-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    defer {
        try? FileManager.default.removeItem(at: url)
    }
    try await body(url)
}
