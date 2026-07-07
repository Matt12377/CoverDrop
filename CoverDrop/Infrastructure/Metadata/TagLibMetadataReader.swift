import AVFoundation
import CTagLib
import Foundation
import ImageIO
import UniformTypeIdentifiers

struct TagLibMetadataReader: AudioMetadataReading {
    nonisolated func readMetadata(
        at url: URL,
        includingEmbeddedArtwork: Bool
    ) async throws -> AudioMetadata {
        let metadata = try await Task.detached(priority: .utility) {
            try Self.readSynchronously(at: url)
        }.value
        let embeddedArtworkURL = includingEmbeddedArtwork
            ? await Self.embeddedArtworkURL(from: url)
            : nil

        return AudioMetadata(
            title: metadata.title,
            artist: metadata.artist,
            albumArtist: metadata.albumArtist,
            album: metadata.album,
            discNumber: metadata.discNumber,
            trackNumber: metadata.trackNumber,
            durationSeconds: metadata.durationSeconds,
            embeddedArtworkURL: embeddedArtworkURL
        )
    }

    nonisolated private static func readSynchronously(at url: URL) throws -> AudioMetadata {
        let file = url.path.withCString { taglib_file_new($0) }
        guard let file else {
            throw TagLibReadError.cannotOpen(url.lastPathComponent)
        }
        defer { taglib_file_free(file) }

        guard taglib_file_is_valid(file) != 0 else {
            throw TagLibReadError.invalidFile(url.lastPathComponent)
        }

        let duration: Int?
        if let properties = taglib_file_audioproperties(file) {
            let value = taglib_audioproperties_length(properties)
            duration = value > 0 ? Int(value) : nil
        } else {
            duration = nil
        }

        return AudioMetadata(
            title: firstProperty("TITLE", in: UnsafePointer(file)),
            artist: firstProperty("ARTIST", in: UnsafePointer(file)),
            albumArtist: firstProperty("ALBUMARTIST", in: UnsafePointer(file)),
            album: firstProperty("ALBUM", in: UnsafePointer(file)),
            discNumber: integerPrefix(firstProperty("DISCNUMBER", in: UnsafePointer(file))),
            trackNumber: integerPrefix(firstProperty("TRACKNUMBER", in: UnsafePointer(file))),
            durationSeconds: duration
        )
    }

    nonisolated private static func firstProperty(
        _ key: String,
        in file: UnsafePointer<TagLib_File>
    ) -> String? {
        let values = key.withCString { taglib_property_get(file, $0) }
        guard let values else { return nil }
        defer { taglib_property_free(values) }
        guard let first = values.pointee else { return nil }

        let value = String(cString: first).trimmingCharacters(in: .whitespacesAndNewlines)
        return value.isEmpty ? nil : value
    }

    nonisolated private static func integerPrefix(_ value: String?) -> Int? {
        guard let value else { return nil }
        let prefix = value.prefix { $0.isNumber }
        return Int(prefix)
    }

    nonisolated private static func embeddedArtworkURL(from url: URL) async -> URL? {
        let asset = AVURLAsset(url: url)
        guard let commonMetadata = try? await asset.load(.commonMetadata) else {
            return nil
        }
        let artworkItems = AVMetadataItem.metadataItems(
            from: commonMetadata,
            filteredByIdentifier: .commonIdentifierArtwork
        )

        for item in artworkItems {
            if let data = try? await item.load(.dataValue),
               let exportedURL = exportEmbeddedArtwork(data, audioURL: url) {
                return exportedURL
            }

            if let value = try? await item.load(.value) as? Data,
               let exportedURL = exportEmbeddedArtwork(value, audioURL: url) {
                return exportedURL
            }
        }

        return nil
    }

    nonisolated private static func exportEmbeddedArtwork(
        _ data: Data,
        audioURL: URL
    ) -> URL? {
        guard let fileExtension = imageFileExtension(for: data) else { return nil }

        do {
            let cacheDirectory = try embeddedArtworkCacheDirectory()
            let outputURL = cacheDirectory.appendingPathComponent(
                "\(stableCacheKey(for: audioURL)).\(fileExtension)"
            )
            if !FileManager.default.fileExists(atPath: outputURL.path) {
                try data.write(to: outputURL, options: .atomic)
            }
            return outputURL
        } catch {
            return nil
        }
    }

    nonisolated private static func embeddedArtworkCacheDirectory() throws -> URL {
        let baseURL = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first
            ?? FileManager.default.temporaryDirectory
        let directory = baseURL
            .appendingPathComponent("CoverDrop", isDirectory: true)
            .appendingPathComponent("EmbeddedArtwork", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory
    }

    nonisolated private static func imageFileExtension(for data: Data) -> String? {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil),
              CGImageSourceGetCount(source) > 0,
              let type = CGImageSourceGetType(source) else {
            return nil
        }

        let preferredExtension = UTType(type as String)?.preferredFilenameExtension
        return preferredExtension?.isEmpty == false ? preferredExtension : "jpg"
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

enum TagLibReadError: LocalizedError, Equatable {
    case cannotOpen(String)
    case invalidFile(String)

    var errorDescription: String? {
        switch self {
        case .cannotOpen(let name):
            "TagLib 无法打开音频：\(name)"
        case .invalidFile(let name):
            "音频内容无效或格式不受支持：\(name)"
        }
    }
}
