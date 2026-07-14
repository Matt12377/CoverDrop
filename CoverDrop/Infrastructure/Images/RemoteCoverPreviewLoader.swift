import AppKit
import Foundation
import ImageIO

enum RemoteCoverPreviewLoader {
    private enum DecodeFailure: Error {
        case invalidImage
    }

    nonisolated(unsafe) private static let decodedImageCache: NSCache<NSURL, NSImage> = {
        let cache = NSCache<NSURL, NSImage>()
        cache.countLimit = 200
        cache.totalCostLimit = 64 * 1024 * 1024
        return cache
    }()
    nonisolated private static let remoteImageDataCache = RemoteCoverImageDataCache()

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
        await loadImage(from: url) {
            let request = previewImageRequest(for: url)
            let (data, response) = try await URLSession.shared.data(for: request)
            guard let httpResponse = response as? HTTPURLResponse,
                  (200 ..< 400).contains(httpResponse.statusCode),
                  data.count <= CoverImageStagingCache.maxRemoteImageBytes else {
                throw URLError(.badServerResponse)
            }
            return data
        }
    }

    nonisolated static func loadImage(
        from url: URL,
        load: @escaping RemoteCoverImageDataCache.Loader
    ) async -> NSImage? {
        if let cachedImage = decodedImageCache.object(forKey: url as NSURL) {
            return cachedImage
        }

        do {
            let data = try await remoteImageDataCache.value(for: url) {
                let data = try await load()
                guard data.count <= CoverImageStagingCache.maxRemoteImageBytes,
                      let decoded = await decodedImageOffMainActor(data: data, maxPixelSize: 480) else {
                    throw DecodeFailure.invalidImage
                }
                store(decoded.image, for: url)
                return data
            }
            if let cachedImage = decodedImageCache.object(forKey: url as NSURL) {
                return cachedImage
            }
            guard let decoded = await decodedImageOffMainActor(data: data, maxPixelSize: 480) else {
                return nil
            }
            store(decoded.image, for: url)
            return decoded.image
        } catch {
            return nil
        }
    }

    nonisolated static func cachedImage(for url: URL, data: Data) -> NSImage? {
        let key = url as NSURL
        if let cachedImage = decodedImageCache.object(forKey: key) {
            return cachedImage
        }

        guard let image = downsampledImage(data: data, maxPixelSize: 480) else {
            return nil
        }
        store(image, for: url)
        return image
    }

    nonisolated private static func decodedImageOffMainActor(
        data: Data,
        maxPixelSize: Int
    ) async -> SendableNSImage? {
        await Task.detached(priority: .utility) {
            downsampledImage(data: data, maxPixelSize: maxPixelSize)
                .map(SendableNSImage.init(image:))
        }.value
    }

    nonisolated private static func downsampledImage(
        data: Data,
        maxPixelSize: Int
    ) -> NSImage? {
        let sourceOptions = [kCGImageSourceShouldCache: false] as CFDictionary
        let thumbnailOptions = [
            kCGImageSourceShouldCacheImmediately: true,
            kCGImageSourceThumbnailMaxPixelSize: maxPixelSize,
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true
        ] as CFDictionary
        guard let source = CGImageSourceCreateWithData(data as CFData, sourceOptions),
              CGImageSourceGetCount(source) > 0,
              let cgImage = CGImageSourceCreateThumbnailAtIndex(source, 0, thumbnailOptions) else {
            return nil
        }
        return NSImage(
            cgImage: cgImage,
            size: NSSize(width: cgImage.width, height: cgImage.height)
        )
    }

    nonisolated private static func store(_ image: NSImage, for url: URL) {
        let pixelCost = Int(max(1, image.size.width * image.size.height * 4))
        decodedImageCache.setObject(image, forKey: url as NSURL, cost: pixelCost)
    }
}
