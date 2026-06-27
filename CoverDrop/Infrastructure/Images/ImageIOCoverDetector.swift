import Foundation
import ImageIO

struct ImageIOCoverDetector: CoverDetecting {
    func detectCover(in albumURL: URL) async throws -> CoverDetectionResult {
        try await Task.detached(priority: .utility) {
            try Self.detectSynchronously(in: albumURL)
        }.value
    }

    nonisolated private static func detectSynchronously(
        in albumURL: URL
    ) throws -> CoverDetectionResult {
        let files = try recursiveFiles(in: albumURL)
        var validImages: [CoverCandidate] = []
        var validNamedImages: [CoverCandidate] = []
        var invalid: [String] = []

        for file in files {
            let priority = namePriority(for: file)
            guard priority != nil || hasSupportedImageExtension(file) else { continue }
            let relativePath = relativePath(of: file, under: albumURL)

            if canReadImageMetadata(at: file) {
                let depth = max(0, relativePath.split(separator: "/").count - 1)
                let candidate = CoverCandidate(
                    url: file,
                    relativePath: relativePath,
                    namePriority: priority ?? 3,
                    depth: depth
                )
                validImages.append(candidate)
                if priority != nil {
                    validNamedImages.append(candidate)
                }
            } else if priority != nil {
                invalid.append(relativePath)
            }
        }

        let selected: CoverCandidate?
        if validImages.count == 1 {
            selected = validImages[0]
        } else {
            selected = sortedByCoverPriority(validNamedImages).first
        }

        return CoverDetectionResult(
            selected: selectedWithPreviewCache(selected),
            invalidNamedPaths: invalid.sorted()
        )
    }

    nonisolated private static func recursiveFiles(in root: URL) throws -> [URL] {
        guard let enumerator = FileManager.default.enumerator(
            at: root,
            includingPropertiesForKeys: [.isRegularFileKey, .isSymbolicLinkKey, .isHiddenKey],
            options: [.skipsHiddenFiles, .skipsPackageDescendants]
        ) else { return [] }

        var result: [URL] = []
        for case let url as URL in enumerator {
            let values = try url.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey])
            if values.isSymbolicLink == true {
                enumerator.skipDescendants()
                continue
            }
            if values.isRegularFile == true { result.append(url) }
        }
        return result
    }

    nonisolated private static func namePriority(for url: URL) -> Int? {
        switch url.deletingPathExtension().lastPathComponent.lowercased() {
        case "cover": 0
        case "folder": 1
        case "front": 2
        default: nil
        }
    }

    nonisolated private static func hasSupportedImageExtension(_ url: URL) -> Bool {
        imageExtensions.contains(url.pathExtension.lowercased())
    }

    nonisolated private static var imageExtensions: Set<String> {
        ["jpg", "jpeg", "png", "webp", "heic", "heif", "tif", "tiff", "bmp", "gif", "avif"]
    }

    nonisolated private static func sortedByCoverPriority(
        _ candidates: [CoverCandidate]
    ) -> [CoverCandidate] {
        candidates.sorted {
            if $0.depth != $1.depth { return $0.depth < $1.depth }
            if $0.namePriority != $1.namePriority { return $0.namePriority < $1.namePriority }
            return $0.relativePath.localizedStandardCompare($1.relativePath) == .orderedAscending
        }
    }

    nonisolated private static func canReadImageMetadata(at url: URL) -> Bool {
        let sourceOptions = [
            kCGImageSourceShouldCache: false
        ] as CFDictionary
        guard let source = CGImageSourceCreateWithURL(url as CFURL, sourceOptions),
              CGImageSourceGetCount(source) > 0,
              let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, sourceOptions) as? [CFString: Any],
              let width = properties[kCGImagePropertyPixelWidth] as? NSNumber,
              let height = properties[kCGImagePropertyPixelHeight] as? NSNumber else {
            return false
        }
        return width.intValue > 0 && height.intValue > 0
    }

    nonisolated private static func selectedWithPreviewCache(
        _ candidate: CoverCandidate?
    ) -> CoverCandidate? {
        guard let candidate else { return nil }

        return CoverCandidate(
            url: candidate.url,
            previewURL: CoverPreviewCache.cachedPreviewURL(for: candidate.url),
            relativePath: candidate.relativePath,
            namePriority: candidate.namePriority,
            depth: candidate.depth,
            source: candidate.source
        )
    }

    nonisolated private static func relativePath(of url: URL, under root: URL) -> String {
        let normalizedRoot = root.standardizedFileURL.resolvingSymlinksInPath().path
        let normalizedURL = url.standardizedFileURL.resolvingSymlinksInPath().path
        let rootPrefix = normalizedRoot.hasSuffix("/") ? normalizedRoot : normalizedRoot + "/"
        guard normalizedURL.hasPrefix(rootPrefix) else { return url.lastPathComponent }
        return String(normalizedURL.dropFirst(rootPrefix.count))
    }
}
