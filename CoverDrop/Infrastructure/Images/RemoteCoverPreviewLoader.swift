import AppKit
import Foundation

enum RemoteCoverPreviewLoader {
    nonisolated static func previewURL(for result: CoverSearchResult) -> URL {
        result.thumbnailURL
    }

    nonisolated static func previewImageRequest(for url: URL) -> URLRequest {
        var request = remoteImageRequest(for: url)
        request.cachePolicy = .returnCacheDataElseLoad
        request.timeoutInterval = 15
        return request
    }

    nonisolated static func remoteImageRequest(for url: URL) -> URLRequest {
        CoverImageStagingCache.remoteImageRequest(for: url)
    }

    nonisolated static func loadImage(from url: URL) async -> NSImage? {
        do {
            let request = previewImageRequest(for: url)
            let (data, response) = try await URLSession.shared.data(for: request)
            guard let httpResponse = response as? HTTPURLResponse,
                  (200 ..< 400).contains(httpResponse.statusCode),
                  data.count <= CoverImageStagingCache.maxRemoteImageBytes else {
                return nil
            }
            return NSImage(data: data)
        } catch {
            return nil
        }
    }
}
