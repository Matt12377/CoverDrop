import Foundation
import Testing
@testable import CoverDrop

struct RemoteCoverPreviewLoaderTests {
    @Test("聚合结果列表预览使用缩略图 URL")
    func previewURLUsesThumbnailURL() throws {
        let thumbnailURL = try #require(URL(string: "https://example.com/cover-100.jpg"))
        let imageURL = try #require(URL(string: "https://example.com/cover-1200.jpg"))
        let result = CoverSearchResult(
            id: "sample",
            sourceName: "测试",
            albumName: "专辑",
            artistName: "艺人",
            thumbnailURL: thumbnailURL,
            imageURL: imageURL,
            externalURL: nil
        )

        #expect(RemoteCoverPreviewLoader.previewURL(for: result) == thumbnailURL)
    }

    @Test("聚合结果封面预览请求复用豆瓣图片 Referer 规则")
    func previewRequestUsesDoubanReferer() throws {
        let url = try #require(URL(string: "https://img9.doubanio.com/view/subject/l/public/s3737076.jpg"))

        let request = RemoteCoverPreviewLoader.previewImageRequest(for: url)

        #expect(request.url == url)
        #expect(request.value(forHTTPHeaderField: "Referer") == "https://music.douban.com/")
        #expect(request.value(forHTTPHeaderField: "User-Agent")?.contains("Safari") == true)
        #expect(request.value(forHTTPHeaderField: "Accept")?.contains("image/") == true)
    }

    @Test("聚合结果封面预览请求允许复用缓存")
    func previewRequestCanReuseCachedData() throws {
        let url = try #require(URL(string: "https://example.com/cover-100.jpg"))

        let request = RemoteCoverPreviewLoader.previewImageRequest(for: url)

        #expect(request.cachePolicy == .returnCacheDataElseLoad)
    }

    @Test("聚合结果缩略图按 URL 复用已解码图片")
    func previewImageReusesDecodedImageForSameURL() throws {
        let url = try #require(URL(string: "https://example.com/cached-cover.png"))
        let validPNG = try #require(Data(base64Encoded:
            "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mNk+A8AAQUBAScY42YAAAAASUVORK5CYII="
        ))

        let first = RemoteCoverPreviewLoader.cachedImage(for: url, data: validPNG)
        let second = RemoteCoverPreviewLoader.cachedImage(for: url, data: Data("不是图片".utf8))

        #expect(first != nil)
        #expect(second != nil)
        #expect(first === second)
    }

    @Test("已解码缓存命中时不再读取远程数据")
    func decodedCacheHitSkipsDataLoader() async throws {
        let url = try #require(URL(string: "https://example.com/decoded-first-\(UUID().uuidString).png"))
        let validPNG = try #require(Data(base64Encoded:
            "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mNk+A8AAQUBAScY42YAAAAASUVORK5CYII="
        ))
        let counter = PreviewDataLoaderCounter()
        _ = try #require(RemoteCoverPreviewLoader.cachedImage(for: url, data: validPNG))

        let image = await RemoteCoverPreviewLoader.loadImage(from: url) {
            await counter.load(validPNG)
        }

        #expect(image != nil)
        #expect(await counter.count == 0)
    }

    @Test("无效图片不会污染远程数据或解码缓存")
    func invalidImageIsNotCached() async throws {
        let url = try #require(URL(string: "https://example.com/invalid-\(UUID().uuidString).png"))
        let validPNG = try #require(Data(base64Encoded:
            "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mNk+A8AAQUBAScY42YAAAAASUVORK5CYII="
        ))
        let counter = PreviewDataLoaderCounter()

        let first = await RemoteCoverPreviewLoader.loadImage(from: url) {
            await counter.load(Data("不是图片".utf8))
        }
        let second = await RemoteCoverPreviewLoader.loadImage(from: url) {
            await counter.load(validPNG)
        }

        #expect(first == nil)
        #expect(second != nil)
        #expect(await counter.count == 2)
    }
}

private actor PreviewDataLoaderCounter {
    private(set) var count = 0

    func load(_ data: Data) -> Data {
        count += 1
        return data
    }
}
