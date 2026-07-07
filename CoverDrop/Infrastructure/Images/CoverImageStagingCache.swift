import Foundation
import ImageIO

enum CoverImageStagingCache {
    enum Failure: LocalizedError, Equatable {
        case unsupportedRemoteURL
        case remoteDownloadFailed(String)
        case nonHTTPResponse
        case nonImageResponse(String?)
        case imageTooLarge
        case unreadableImage
        case cannotCreateCacheDirectory

        var errorDescription: String? {
            switch self {
            case .unsupportedRemoteURL:
                "只支持拖入本地图片，或网页里的 http/https 图片。"
            case .remoteDownloadFailed(let reason):
                "无法下载网页图片：\(reason)"
            case .nonHTTPResponse:
                "网页图片下载没有返回 HTTP 响应。"
            case .nonImageResponse(let mimeType):
                if let mimeType {
                    "拖入的网页内容不是图片（MIME：\(mimeType)）。"
                } else {
                    "拖入的网页内容不是图片。"
                }
            case .imageTooLarge:
                "图片太大，已拒绝暂存。"
            case .unreadableImage:
                "无法读取这张图片。"
            case .cannotCreateCacheDirectory:
                "无法创建临时封面缓存目录。"
            }
        }
    }

    nonisolated static let maxRemoteImageBytes = 20 * 1024 * 1024

    nonisolated static func stageImageData(
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

    nonisolated static func stageRemoteImage(at url: URL) async throws -> URL {
        guard ["http", "https"].contains(url.scheme?.lowercased()) else {
            CoverDropDebugLog.write("封面下载：拒绝非 http/https URL：\(url.absoluteString)")
            throw Failure.unsupportedRemoteURL
        }

        let request = remoteImageRequest(for: url)
        CoverDropDebugLog.write(
            "封面下载：开始请求 \(url.absoluteString)，UA=\(request.value(forHTTPHeaderField: "User-Agent") ?? "")，Referer=\(request.value(forHTTPHeaderField: "Referer") ?? "无")"
        )

        let urlResponse: URLResponse
        let data: Data
        do {
            (data, urlResponse) = try await URLSession.shared.data(for: request)
        } catch {
            let reason = networkFailureDescription(for: error)
            CoverDropDebugLog.write("封面下载：请求失败，URL=\(url.absoluteString)，原因=\(reason)")
            throw Failure.remoteDownloadFailed(reason)
        }

        guard let response = urlResponse as? HTTPURLResponse else {
            CoverDropDebugLog.write("封面下载：响应不是 HTTPURLResponse，URL=\(url.absoluteString)")
            throw Failure.nonHTTPResponse
        }

        let mimeType = response.mimeType?.lowercased()
        CoverDropDebugLog.write(
            "封面下载：收到响应，URL=\(url.absoluteString)，状态码=\(response.statusCode)，MIME=\(mimeType ?? "无")，大小=\(data.count) bytes"
        )

        guard (200 ..< 400).contains(response.statusCode) else {
            let reason = remoteDownloadFailureReason(
                statusCode: response.statusCode,
                url: url,
                request: request,
                data: data
            )
            CoverDropDebugLog.write("封面下载：失败，URL=\(url.absoluteString)，原因=\(reason)")
            throw Failure.remoteDownloadFailed(reason)
        }

        if data.count > maxRemoteImageBytes {
            CoverDropDebugLog.write(
                "封面下载：失败，URL=\(url.absoluteString)，原因=图片过大 \(data.count) bytes，限制=\(maxRemoteImageBytes) bytes"
            )
            throw Failure.imageTooLarge
        }

        if let mimeType, !mimeType.hasPrefix("image/") {
            CoverDropDebugLog.write("封面下载：失败，URL=\(url.absoluteString)，原因=非图片 MIME \(mimeType)")
            throw Failure.nonImageResponse(mimeType)
        }

        do {
            let stagedURL = try stageImageData(
                data,
                suggestedExtension: imageExtension(from: url, mimeType: mimeType)
            )
            CoverDropDebugLog.write("封面下载：图片验证和缓存写入成功，URL=\(url.absoluteString)，缓存=\(stagedURL.path)")
            return stagedURL
        } catch {
            CoverDropDebugLog.write(
                "封面下载：图片验证或缓存写入失败，URL=\(url.absoluteString)，原因=\(error.localizedDescription)"
            )
            throw error
        }
    }

    nonisolated static func remoteImageRequest(for url: URL) -> URLRequest {
        var request = URLRequest(url: url)
        request.cachePolicy = .reloadIgnoringLocalCacheData
        request.timeoutInterval = 30
        request.setValue(
            "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/17.0 Safari/605.1.15",
            forHTTPHeaderField: "User-Agent"
        )
        request.setValue(
            "image/avif,image/webp,image/apng,image/svg+xml,image/*,*/*;q=0.8",
            forHTTPHeaderField: "Accept"
        )
        if let referer = imageReferer(for: url) {
            request.setValue(referer, forHTTPHeaderField: "Referer")
            CoverDropDebugLog.write("封面下载：为 \(url.host(percentEncoded: false) ?? "未知域名") 设置 Referer：\(referer)")
        }
        return request
    }

    nonisolated static func imageReferer(for url: URL) -> String? {
        guard let host = url.host(percentEncoded: false)?.lowercased() else {
            return nil
        }

        if host == "doubanio.com" || host.hasSuffix(".doubanio.com") {
            return "https://music.douban.com/"
        }

        return nil
    }

    nonisolated private static func validateImageData(_ data: Data) throws {
        guard !data.isEmpty,
              let source = CGImageSourceCreateWithData(data as CFData, nil),
              CGImageSourceGetCount(source) > 0 else {
            throw Failure.unreadableImage
        }
    }

    nonisolated private static func pendingCoverDirectory() throws -> URL {
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

    nonisolated private static func imageExtension(
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

    nonisolated private static func normalizedImageExtension(_ candidate: String?) -> String {
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

    nonisolated private static func networkFailureDescription(for error: Error) -> String {
        let nsError = error as NSError
        return "\(nsError.domain) \(nsError.code)：\(nsError.localizedDescription)"
    }

    nonisolated private static func remoteDownloadFailureReason(
        statusCode: Int,
        url: URL,
        request: URLRequest,
        data: Data
    ) -> String {
        var reason = "HTTP 状态码 \(statusCode)"
        if statusCode == 418,
           imageReferer(for: url) != nil,
           request.value(forHTTPHeaderField: "Referer") == nil {
            reason += "；豆瓣图片需要 Referer，但当前请求未设置"
        }

        if let body = String(data: data.prefix(120), encoding: .utf8),
           !body.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            reason += "；响应片段：\(body)"
        }

        return reason
    }
}
