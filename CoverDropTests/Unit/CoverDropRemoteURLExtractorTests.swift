import Foundation
import Testing
@testable import CoverDrop

struct CoverDropRemoteURLExtractorTests {
    @Test("从 NSItemProvider 错误文案中提取 Apple CDN 图片 URL")
    func extractsAppleImageURLFromProviderErrorMessage() throws {
        let value = "URL https://is1-ssl.mzstatic.com/image/thumb/Music128/v4/83/bb/6b/83bb6b59-653d-8032-494f-d24cd5b4a452/wf.jpg/600x600bb-100.jpg is not a file:// URL."

        let url = try #require(CoverDropRemoteURLExtractor.firstRemoteURL(in: value))

        #expect(url.absoluteString == "https://is1-ssl.mzstatic.com/image/thumb/Music128/v4/83/bb/6b/83bb6b59-653d-8032-494f-d24cd5b4a452/wf.jpg/600x600bb-100.jpg")
    }

    @Test("远程 URL 末尾标点不会进入提取结果")
    func trimsTrailingPunctuation() throws {
        let value = "下载失败：https://is1-ssl.mzstatic.com/image/thumb/example.jpg/600x600bb-100.jpg."

        let url = try #require(CoverDropRemoteURLExtractor.firstRemoteURL(in: value))

        #expect(url.absoluteString == "https://is1-ssl.mzstatic.com/image/thumb/example.jpg/600x600bb-100.jpg")
    }

    @Test("递归检查 NSError 的 underlying error 和 userInfo")
    func extractsURLFromNestedNSError() throws {
        let underlying = NSError(
            domain: "NSCocoaErrorDomain",
            code: 256,
            userInfo: [
                NSLocalizedDescriptionKey: "URL https://is1-ssl.mzstatic.com/image/thumb/Music112/v4/c8/02/ad/c802ad4e-c4d4-7f75-c223-f422ece24db8/4894859315325.jpg/600x600bb-100.jpg is not a file:// URL."
            ]
        )
        let error = NSError(
            domain: "NSItemProviderErrorDomain",
            code: -1000,
            userInfo: [
                NSLocalizedDescriptionKey: "Cannot load representation of type public.file-url",
                NSUnderlyingErrorKey: underlying
            ]
        )

        let url = try #require(CoverDropRemoteURLExtractor.firstRemoteURL(in: error))

        #expect(url.absoluteString == "https://is1-ssl.mzstatic.com/image/thumb/Music112/v4/c8/02/ad/c802ad4e-c4d4-7f75-c223-f422ece24db8/4894859315325.jpg/600x600bb-100.jpg")
    }
}
