import Foundation

struct AudioMetadata: Equatable, Sendable {
    let title: String?
    let artist: String?
    let albumArtist: String?
    let album: String?
    let discNumber: Int?
    let trackNumber: Int?
    let durationSeconds: Int?
    let embeddedArtworkURL: URL?

    nonisolated init(
        title: String?,
        artist: String?,
        albumArtist: String?,
        album: String?,
        discNumber: Int?,
        trackNumber: Int?,
        durationSeconds: Int?,
        embeddedArtworkURL: URL? = nil
    ) {
        self.title = title
        self.artist = artist
        self.albumArtist = albumArtist
        self.album = album
        self.discNumber = discNumber
        self.trackNumber = trackNumber
        self.durationSeconds = durationSeconds
        self.embeddedArtworkURL = embeddedArtworkURL
    }
}

struct AudioFileRecord: Identifiable, Equatable, Sendable {
    nonisolated var id: String { relativePath }
    let url: URL
    let relativePath: String
    let format: String
    let metadata: AudioMetadata?
    let readError: String?
}

enum CoverSource: Equatable, Sendable {
    case file
    case embeddedArtwork

    nonisolated var displayName: String {
        switch self {
        case .file:
            "图片文件"
        case .embeddedArtwork:
            "音频内嵌图"
        }
    }
}

struct CoverCandidate: Identifiable, Equatable, Sendable {
    nonisolated var id: String { url.path }
    let url: URL
    let previewURL: URL?
    let relativePath: String
    let namePriority: Int
    let depth: Int
    let source: CoverSource

    nonisolated init(
        url: URL,
        previewURL: URL? = nil,
        relativePath: String,
        namePriority: Int,
        depth: Int,
        source: CoverSource = .file
    ) {
        self.url = url
        self.previewURL = previewURL
        self.relativePath = relativePath
        self.namePriority = namePriority
        self.depth = depth
        self.source = source
    }

    nonisolated var displayURL: URL {
        previewURL ?? url
    }
}

enum AlbumScanIssue: Equatable, Sendable {
    case singleFileNeedsConfirmation(hasCue: Bool)
    case metadataReadFailed(paths: [String])
    case invalidNamedCovers(paths: [String])
    case uncertainAlbumBoundary(reason: String)
    case trackNamedAudioFiles(paths: [String])

    nonisolated var displayName: String {
        switch self {
        case .singleFileNeedsConfirmation(let hasCue):
            hasCue ? "单文件整轨，需要确认" : "单文件发行，需要确认"
        case .metadataReadFailed(let paths):
            "\(paths.count) 个音频标签读取失败"
        case .invalidNamedCovers(let paths):
            "\(paths.count) 个常见封面文件损坏"
        case .uncertainAlbumBoundary(let reason):
            "专辑边界需要确认：\(reason)"
        case .trackNamedAudioFiles(let paths):
            "\(paths.count) 个 track 音轨需要确认"
        }
    }
}

struct AlbumScanRecord: Identifiable, Equatable, Sendable {
    nonisolated var id: String { folderURL.path }
    let folderURL: URL
    let artistName: String
    let albumName: String
    let audioFiles: [AudioFileRecord]
    let displayedCover: CoverCandidate?
    let issues: [AlbumScanIssue]

    nonisolated var needsAttention: Bool { !issues.isEmpty }
}

struct LibraryScanResult: Equatable, Sendable {
    let albums: [AlbumScanRecord]
    let looseAudioPaths: [String]

    nonisolated var albumsWithCover: Int {
        albums.count { $0.displayedCover != nil }
    }

    nonisolated var albumsNeedingAttention: Int {
        albums.count { $0.needsAttention }
    }
}
