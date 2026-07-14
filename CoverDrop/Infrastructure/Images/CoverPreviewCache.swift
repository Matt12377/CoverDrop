import Foundation
import AppKit
import ImageIO

enum CoverPreviewCache {
    nonisolated(unsafe) private static let memoryCache: NSCache<NSString, NSURL> = {
        let cache = NSCache<NSString, NSURL>()
        cache.countLimit = 2_000
        return cache
    }()
    nonisolated(unsafe) private static let imageCache: NSCache<NSString, NSImage> = {
        let cache = NSCache<NSString, NSImage>()
        cache.countLimit = 500
        cache.totalCostLimit = 256 * 1024 * 1024
        return cache
    }()
    nonisolated private static let imageCacheKeyLock = NSLock()
    nonisolated(unsafe) private static var imageCacheKeysByPath: [String: Set<String>] = [:]

    nonisolated static func cachedPreviewURL(for sourceURL: URL) -> URL? {
        let key = previewMemoryCacheKey(for: sourceURL) as NSString
        if let cached = memoryCache.object(forKey: key) {
            return cached as URL
        }

        do {
            let url = try cachePreview(for: sourceURL, replacingExisting: false)
            memoryCache.setObject(url as NSURL, forKey: key)
            return url
        } catch {
            return nil
        }
    }

    nonisolated static func refreshedPreviewURL(for sourceURL: URL) -> URL? {
        let key = previewMemoryCacheKey(for: sourceURL) as NSString
        do {
            let url = try cachePreview(for: sourceURL, replacingExisting: true)
            memoryCache.setObject(url as NSURL, forKey: key)
            CoverDropDebugLog.write("封面预览：刷新成功 sourceURL=\(sourceURL.path) -> previewURL=\(url.path)")
            return url
        } catch {
            CoverDropDebugLog.write("封面预览：刷新失败 sourceURL=\(sourceURL.path)，error=\(error.localizedDescription)")
            return nil
        }
    }

    nonisolated static func refreshedPreviewURLForUpdatedCover(_ sourceURL: URL) -> URL? {
        invalidateImageCache(for: sourceURL)
        let previewURL = refreshedPreviewURL(for: sourceURL)
        if let previewURL {
            invalidateImageCache(for: previewURL)
        }
        return previewURL
    }

    nonisolated static func clearMemoryCache() {
        memoryCache.removeAllObjects()
        imageCache.removeAllObjects()
        imageCacheKeyLock.withLock {
            imageCacheKeysByPath.removeAll()
        }
    }

    nonisolated static func cachedImage(for sourceURL: URL, maxPixelSize: CGFloat = 300) -> NSImage? {
        let cacheKey = imageCacheKey(for: sourceURL, maxPixelSize: maxPixelSize)
        return cachedImage(for: sourceURL, maxPixelSize: maxPixelSize, cacheKey: cacheKey)
    }

    nonisolated static func cachedImage(
        for sourceURL: URL,
        maxPixelSize: CGFloat,
        contentRevision: UInt64
    ) -> NSImage? {
        let fileCacheKey = imageCacheKey(for: sourceURL, maxPixelSize: maxPixelSize)
        let cacheKey = "\(fileCacheKey)|revision:\(contentRevision)"
        return cachedImage(for: sourceURL, maxPixelSize: maxPixelSize, cacheKey: cacheKey)
    }

    nonisolated private static func cachedImage(
        for sourceURL: URL,
        maxPixelSize: CGFloat,
        cacheKey: String
    ) -> NSImage? {
        let key = cacheKey as NSString
        if let cached = imageCache.object(forKey: key) {
            return cached
        }

        let options = [
            kCGImageSourceShouldCache: false,
            kCGImageSourceThumbnailMaxPixelSize: maxPixelSize,
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true
        ] as CFDictionary

        guard let source = CGImageSourceCreateWithURL(sourceURL as CFURL, options),
              CGImageSourceGetCount(source) > 0,
              let cgImage = CGImageSourceCreateThumbnailAtIndex(source, 0, options) else {
            return nil
        }

        let image = NSImage(
            cgImage: cgImage,
            size: NSSize(width: cgImage.width, height: cgImage.height)
        )
        imageCache.setObject(image, forKey: key, cost: max(1, cgImage.bytesPerRow * cgImage.height))
        rememberImageCacheKey(cacheKey, for: sourceURL)
        return image
    }

    nonisolated static func invalidateImageCache(for sourceURL: URL) {
        let path = sourceURL.standardizedFileURL.path
        let keys = imageCacheKeyLock.withLock {
            imageCacheKeysByPath.removeValue(forKey: path) ?? []
        }
        for key in keys {
            imageCache.removeObject(forKey: key as NSString)
        }
    }

    nonisolated static func thumbnailIdentity(for sourceURL: URL?, maxPixelSize: CGFloat) -> String {
        guard let sourceURL else { return "empty@\(Int(maxPixelSize))" }
        return imageCacheKey(for: sourceURL, maxPixelSize: maxPixelSize)
    }

    nonisolated private static func cachePreview(
        for sourceURL: URL,
        replacingExisting: Bool
    ) throws -> URL {
        let cacheDirectory = try coverPreviewCacheDirectory()
        let fileExtension = sourceURL.pathExtension.isEmpty ? "image" : sourceURL.pathExtension
        let destinationURL = cacheDirectory.appendingPathComponent(
            "\(stableCacheKey(for: sourceURL)).\(fileExtension)"
        )

        if replacingExisting, FileManager.default.fileExists(atPath: destinationURL.path) {
            try FileManager.default.removeItem(at: destinationURL)
        }

        if FileManager.default.fileExists(atPath: destinationURL.path) {
            return destinationURL
        }

        do {
            try FileManager.default.copyItem(at: sourceURL, to: destinationURL)
        } catch {
            if FileManager.default.fileExists(atPath: destinationURL.path) {
                return destinationURL
            }
            throw error
        }
        return destinationURL
    }

    nonisolated private static func coverPreviewCacheDirectory() throws -> URL {
        let baseURL = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first
            ?? FileManager.default.temporaryDirectory
        let directory = baseURL
            .appendingPathComponent("CoverDrop", isDirectory: true)
            .appendingPathComponent("CoverPreviews", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory
    }

    nonisolated private static func stableCacheKey(for url: URL) -> String {
        let identity = fileIdentity(for: url)
        let seed = "\(identity.path)|\(identity.modificationTimestamp)|\(identity.fileSize)"
        var hash: UInt64 = 1_469_598_103_934_665_603
        for byte in seed.utf8 {
            hash ^= UInt64(byte)
            hash &*= 1_099_511_628_211
        }
        return String(hash, radix: 16)
    }

    nonisolated private static func imageCacheKey(for url: URL, maxPixelSize: CGFloat) -> String {
        let identity = fileIdentity(for: url)
        return "\(identity.path)|\(identity.modificationTimestamp)|\(identity.fileSize)@\(Int(maxPixelSize))"
    }

    nonisolated private static func previewMemoryCacheKey(for url: URL) -> String {
        let identity = fileIdentity(for: url)
        return "\(identity.path)|\(identity.modificationTimestamp)|\(identity.fileSize)"
    }

    nonisolated private static func rememberImageCacheKey(_ key: String, for url: URL) {
        let path = url.standardizedFileURL.path
        imageCacheKeyLock.withLock {
            var keys = imageCacheKeysByPath[path] ?? []
            keys.insert(key)
            imageCacheKeysByPath[path] = keys
        }
    }

    nonisolated private static func fileIdentity(for url: URL) -> (path: String, modificationTimestamp: TimeInterval, fileSize: Int64) {
        var fileURL = url.standardizedFileURL
        fileURL.removeAllCachedResourceValues()
        let values = try? fileURL.resourceValues(forKeys: [.contentModificationDateKey, .fileSizeKey])
        return (
            fileURL.path,
            values?.contentModificationDate?.timeIntervalSince1970 ?? 0,
            Int64(values?.fileSize ?? 0)
        )
    }
}
