import Foundation

enum CoverPreviewCache {
    nonisolated static func cachedPreviewURL(for sourceURL: URL) -> URL? {
        do {
            return try cachePreview(for: sourceURL, replacingExisting: false)
        } catch {
            return nil
        }
    }

    nonisolated static func refreshedPreviewURL(for sourceURL: URL) -> URL? {
        do {
            return try cachePreview(for: sourceURL, replacingExisting: true)
        } catch {
            return nil
        }
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
        let modificationTimestamp = (try? url.resourceValues(forKeys: [.contentModificationDateKey]))
            .flatMap(\.contentModificationDate)?
            .timeIntervalSince1970 ?? 0
        let seed = "\(url.standardizedFileURL.path)|\(modificationTimestamp)"
        var hash: UInt64 = 1_469_598_103_934_665_603
        for byte in seed.utf8 {
            hash ^= UInt64(byte)
            hash &*= 1_099_511_628_211
        }
        return String(hash, radix: 16)
    }
}
