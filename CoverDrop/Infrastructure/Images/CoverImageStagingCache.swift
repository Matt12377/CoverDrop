import Foundation
import ImageIO

enum CoverImageStagingCache {
    enum Failure: LocalizedError, Equatable {
        case unsupportedRemoteURL
        case remoteDownloadFailed
        case nonImageResponse
        case imageTooLarge
        case unreadableImage
        case cannotCreateCacheDirectory

        var errorDescription: String? {
            switch self {
            case .unsupportedRemoteURL:
                "只支持拖入本地图片，或网页里的 http/https 图片。"
            case .remoteDownloadFailed:
                "无法下载网页图片，请尝试先拖到桌面再拖入 CoverDrop。"
            case .nonImageResponse:
                "拖入的网页内容不是图片。"
            case .imageTooLarge:
                "图片太大，已拒绝暂存。"
            case .unreadableImage:
                "无法读取这张图片。"
            case .cannotCreateCacheDirectory:
                "无法创建临时封面缓存目录。"
            }
        }
    }

    static let maxRemoteImageBytes = 20 * 1024 * 1024

    static func stageImageData(
        _ data: Data,
        suggestedExtension: String? = nil
    ) throws -> URL {
        try validateImageData(data)

        let directory = try pendingCoverDirectory()
        let fileExtension = normalizedImageExtension(suggestedExtension)
        let stagedURL = directory
            .appendingPathComponent(UUID().uuidString)
            .appendingPathExtension(fileExtension)

        try data.write(to: stagedURL, options: .atomic)
        return stagedURL
    }

    static func stageRemoteImage(at url: URL) async throws -> URL {
        guard ["http", "https"].contains(url.scheme?.lowercased()) else {
            throw Failure.unsupportedRemoteURL
        }

        let response: URLResponse
        let data: Data
        do {
            (data, response) = try await URLSession.shared.data(from: url)
        } catch {
            throw Failure.remoteDownloadFailed
        }

        if let httpResponse = response as? HTTPURLResponse,
           !(200 ..< 400).contains(httpResponse.statusCode) {
            throw Failure.remoteDownloadFailed
        }

        if data.count > maxRemoteImageBytes {
            throw Failure.imageTooLarge
        }

        let mimeType = response.mimeType?.lowercased()
        if let mimeType, !mimeType.hasPrefix("image/") {
            throw Failure.nonImageResponse
        }

        return try stageImageData(
            data,
            suggestedExtension: imageExtension(from: url, mimeType: mimeType)
        )
    }

    private static func validateImageData(_ data: Data) throws {
        guard !data.isEmpty,
              let source = CGImageSourceCreateWithData(data as CFData, nil),
              CGImageSourceGetCount(source) > 0 else {
            throw Failure.unreadableImage
        }
    }

    private static func pendingCoverDirectory() throws -> URL {
        let baseURL = FileManager.default.urls(
            for: .cachesDirectory,
            in: .userDomainMask
        ).first ?? FileManager.default.temporaryDirectory
        let directory = baseURL
            .appendingPathComponent("CoverDrop", isDirectory: true)
            .appendingPathComponent("PendingCovers", isDirectory: true)

        do {
            try FileManager.default.createDirectory(
                at: directory,
                withIntermediateDirectories: true
            )
            return directory
        } catch {
            throw Failure.cannotCreateCacheDirectory
        }
    }

    private static func imageExtension(
        from url: URL,
        mimeType: String?
    ) -> String {
        let pathExtension = normalizedImageExtension(url.pathExtension)
        if pathExtension != "image" {
            return pathExtension
        }

        switch mimeType {
        case "image/jpeg", "image/jpg":
            return "jpg"
        case "image/png":
            return "png"
        case "image/tiff":
            return "tiff"
        case "image/gif":
            return "gif"
        case "image/webp":
            return "webp"
        default:
            return "image"
        }
    }

    private static func normalizedImageExtension(_ candidate: String?) -> String {
        let value = (candidate ?? "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
            .trimmingCharacters(in: CharacterSet(charactersIn: "."))

        switch value {
        case "jpg", "jpeg":
            return "jpg"
        case "png":
            return "png"
        case "tif", "tiff":
            return "tiff"
        case "gif":
            return "gif"
        case "webp":
            return "webp"
        default:
            return "image"
        }
    }
}
