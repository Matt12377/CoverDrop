import Foundation
import ImageIO

struct ImageIOCoverDetector: CoverDetecting {
    nonisolated func detectCover(in albumURL: URL) async throws -> CoverDetectionResult {
        try await Task.detached(priority: .utility) {
            try Self.detectSynchronously(in: albumURL)
        }.value
    }

    nonisolated private static func detectSynchronously(
        in albumURL: URL
    ) throws -> CoverDetectionResult {
        let files = try recursiveFiles(in: albumURL)
        var validImages: [ImageCandidate] = []
        var validNamedImages: [ImageCandidate] = []
        var invalid: [String] = []

        for file in files {
            let priority = namePriority(for: file)
            guard priority != nil || hasSupportedImageExtension(file) else { continue }
            let relativePath = relativePath(of: file, under: albumURL)

            if let size = imageSize(at: file) {
                let depth = max(0, relativePath.split(separator: "/").count - 1)
                let candidate = ImageCandidate(
                    cover: CoverCandidate(
                        url: file,
                        relativePath: relativePath,
                        namePriority: priority ?? 3,
                        depth: depth
                    ),
                    width: size.width,
                    height: size.height
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
            selected = validImages[0].cover
        } else if let namedCover = sortedByCoverPriority(validNamedImages).first {
            selected = namedCover.cover
        } else {
            selected = sortedByHeuristicCoverPriority(validImages).first?.cover
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

    private struct ImageCandidate {
        let cover: CoverCandidate
        let width: Int
        let height: Int

        nonisolated var aspectDeviation: Double {
            Double(abs(width - height)) / Double(max(width, height))
        }

        nonisolated var pixelArea: Int {
            width * height
        }
    }

    nonisolated private static func sortedByCoverPriority(
        _ candidates: [ImageCandidate]
    ) -> [ImageCandidate] {
        candidates.sorted {
            if $0.cover.depth != $1.cover.depth { return $0.cover.depth < $1.cover.depth }
            if $0.cover.namePriority != $1.cover.namePriority {
                return $0.cover.namePriority < $1.cover.namePriority
            }
            return $0.cover.relativePath.localizedStandardCompare($1.cover.relativePath) == .orderedAscending
        }
    }

    nonisolated private static func sortedByHeuristicCoverPriority(
        _ candidates: [ImageCandidate]
    ) -> [ImageCandidate] {
        candidates.sorted {
            if $0.cover.depth != $1.cover.depth { return $0.cover.depth < $1.cover.depth }
            if $0.aspectDeviation != $1.aspectDeviation {
                return $0.aspectDeviation < $1.aspectDeviation
            }
            let lhsNameScore = heuristicNameScore(for: $0.cover.url)
            let rhsNameScore = heuristicNameScore(for: $1.cover.url)
            if lhsNameScore != rhsNameScore { return lhsNameScore < rhsNameScore }
            if $0.pixelArea != $1.pixelArea { return $0.pixelArea > $1.pixelArea }
            return $0.cover.relativePath.localizedStandardCompare($1.cover.relativePath) == .orderedAscending
        }
    }

    nonisolated private static func heuristicNameScore(for url: URL) -> Int {
        let fileName = url.deletingPathExtension().lastPathComponent.lowercased()
        let negativeKeywords = [
            "back", "rear", "tray", "cd", "disc", "booklet", "inlay", "label", "lyrics", "logo",
            "背面", "封底", "碟", "盘", "唱片", "歌词", "内页", "小册子", "标签"
        ]
        if negativeKeywords.contains(where: { fileName.contains($0) }) {
            return 1
        }

        let positiveKeywords = [
            "album", "artwork", "sleeve", "jacket", "scan",
            "封面", "正面", "外盒", "扫描"
        ]
        if positiveKeywords.contains(where: { fileName.contains($0) }) {
            return -1
        }

        return 0
    }

    nonisolated private static func imageSize(at url: URL) -> (width: Int, height: Int)? {
        let sourceOptions = [
            kCGImageSourceShouldCache: false
        ] as CFDictionary
        guard let source = CGImageSourceCreateWithURL(url as CFURL, sourceOptions),
              CGImageSourceGetCount(source) > 0,
              let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, sourceOptions) as? [CFString: Any],
              let width = properties[kCGImagePropertyPixelWidth] as? NSNumber,
              let height = properties[kCGImagePropertyPixelHeight] as? NSNumber else {
            return nil
        }
        guard width.intValue > 0 && height.intValue > 0 else { return nil }
        return (width.intValue, height.intValue)
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
