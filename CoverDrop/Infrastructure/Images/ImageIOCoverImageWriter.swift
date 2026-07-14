import Foundation
import ImageIO
import UniformTypeIdentifiers

struct ImageIOCoverImageWriter: CoverImageWriting {
    enum Failure: LocalizedError, Equatable {
        case unreadableImage
        case cannotCreateJPEG

        var errorDescription: String? {
            switch self {
            case .unreadableImage:
                "拖入的文件不是可读取的图片。"
            case .cannotCreateJPEG:
                "无法把图片转换为 JPEG。"
            }
        }
    }

    nonisolated func writeCoverImage(
        from sourceURL: URL,
        toAlbumFolder albumFolderURL: URL
    ) async throws -> URL {
        return try await Task.detached(priority: .userInitiated) {
            let performanceSpan = CoverDropPerformanceLog.begin(
                CoverDropPerformanceOperation.saveCoverImage,
                context: [
                    "phase": "writer",
                    "sourceExtension": sourceURL.pathExtension.lowercased()
                ]
            )
            do {
                let writtenURL = try Self.writeCoverImageSynchronously(
                    from: sourceURL,
                    toAlbumFolder: albumFolderURL
                )
                performanceSpan?.finish()
                return writtenURL
            } catch {
                performanceSpan?.finish(
                    outcome: .failure,
                    context: ["error": error.localizedDescription]
                )
                throw error
            }
        }.value
    }

    nonisolated private static func writeCoverImageSynchronously(
        from sourceURL: URL,
        toAlbumFolder albumFolderURL: URL
    ) throws -> URL {
        let sourceOptions = [
            kCGImageSourceShouldCache: false
        ] as CFDictionary
        guard let source = CGImageSourceCreateWithURL(sourceURL as CFURL, sourceOptions),
              CGImageSourceGetCount(source) > 0,
              CGImageSourceGetStatus(source) == .statusComplete,
              CGImageSourceGetStatusAtIndex(source, 0) == .statusComplete,
              let image = CGImageSourceCreateImageAtIndex(source, 0, sourceOptions) else {
            throw Failure.unreadableImage
        }

        let destinationURL = albumFolderURL.appendingPathComponent("cover.jpg", isDirectory: false)
        let temporaryURL = albumFolderURL.appendingPathComponent(
            ".cover-\(UUID().uuidString).jpg",
            isDirectory: false
        )

        do {
            if CGImageSourceGetType(source) as String? == UTType.jpeg.identifier {
                try FileManager.default.copyItem(at: sourceURL, to: temporaryURL)
            } else {
                try writeJPEG(image, to: temporaryURL)
            }
            if FileManager.default.fileExists(atPath: destinationURL.path) {
                _ = try FileManager.default.replaceItemAt(
                    destinationURL,
                    withItemAt: temporaryURL,
                    backupItemName: nil,
                    options: [.usingNewMetadataOnly]
                )
            } else {
                try FileManager.default.moveItem(at: temporaryURL, to: destinationURL)
            }
            return destinationURL
        } catch {
            try? FileManager.default.removeItem(at: temporaryURL)
            throw error
        }
    }

    nonisolated private static func writeJPEG(
        _ image: CGImage,
        to url: URL
    ) throws {
        guard let destination = CGImageDestinationCreateWithURL(
            url as CFURL,
            UTType.jpeg.identifier as CFString,
            1,
            nil
        ) else {
            throw Failure.cannotCreateJPEG
        }

        let options = [
            kCGImageDestinationLossyCompressionQuality: 0.92
        ] as CFDictionary
        CGImageDestinationAddImage(destination, image, options)
        guard CGImageDestinationFinalize(destination) else {
            throw Failure.cannotCreateJPEG
        }
    }
}
