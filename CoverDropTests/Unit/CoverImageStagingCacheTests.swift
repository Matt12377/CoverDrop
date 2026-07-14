import Foundation
import Testing
@testable import CoverDrop

struct CoverImageStagingCacheTests {
    @Test("远程图片下载请求带浏览器式图片请求头")
    func remoteImageRequestUsesBrowserLikeImageHeaders() throws {
        let url = try #require(URL(string: "https://is1-ssl.mzstatic.com/image/thumb/example.jpg/600x600bb-100.jpg"))

        let request = CoverImageStagingCache.remoteImageRequest(for: url)

        #expect(request.url == url)
        #expect(request.timeoutInterval == 30)
        #expect(request.cachePolicy == .reloadIgnoringLocalCacheData)
        #expect(request.value(forHTTPHeaderField: "User-Agent")?.contains("Safari") == true)
        #expect(request.value(forHTTPHeaderField: "Accept")?.contains("image/") == true)
        #expect(request.value(forHTTPHeaderField: "Referer") == nil)
    }

    @Test("豆瓣图片下载请求带 music.douban.com Referer")
    func doubanImageRequestUsesDoubanReferer() throws {
        let url = try #require(URL(string: "https://img1.doubanio.com/view/subject/m/public/s33672680.jpg"))

        let request = CoverImageStagingCache.remoteImageRequest(for: url)

        #expect(request.value(forHTTPHeaderField: "Referer") == "https://music.douban.com/")
        #expect(CoverImageStagingCache.imageReferer(for: url) == "https://music.douban.com/")
    }

    @Test("豆瓣子域名图片也会带 Referer")
    func doubanSubdomainImageRequestUsesDoubanReferer() throws {
        let url = try #require(URL(string: "https://img9.doubanio.com/view/subject/l/public/example.jpg"))

        let request = CoverImageStagingCache.remoteImageRequest(for: url)

        #expect(request.value(forHTTPHeaderField: "Referer") == "https://music.douban.com/")
    }

    @Test("预取与暂存路径复用同一远程图片数据")
    func cachedRemoteImageDataReusesPrefetchedData() async throws {
        let url = try #require(URL(string: "https://example.com/prefetched-cover-\(UUID().uuidString).jpg"))
        let loader = RemoteImageDataLoaderCounter()

        let prefetched = try await CoverImageStagingCache.cachedRemoteImageData(for: url) {
            await loader.load(Data([1, 2, 3]))
        }
        let staged = try await CoverImageStagingCache.cachedRemoteImageData(for: url) {
            await loader.load(Data([4, 5, 6]))
        }

        #expect(prefetched == Data([1, 2, 3]))
        #expect(staged == Data([1, 2, 3]))
        #expect(await loader.count == 1)
    }

    @Test("图片校验和落盘工作离开主线程")
    func stagingWorkRunsOffMainThread() async throws {
        let wasMainThread = try await CoverImageStagingCache.runStagingWorkOffMainActor {
            Thread.isMainThread
        }

        #expect(wasMainThread == false)
    }
}

private actor RemoteImageDataLoaderCounter {
    private(set) var count = 0

    func load(_ data: Data) -> Data {
        count += 1
        return data
    }
}
