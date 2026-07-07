import Foundation

struct ScanSnapshot: Codable, Equatable, Sendable {
    nonisolated static let currentSchemaVersion = 1

    let schemaVersion: Int
    let createdAt: Date
    let library: Library
    let scanResult: Result
    let albumNameEnhancement: AlbumNameEnhancement?

    nonisolated init(
        schemaVersion: Int = Self.currentSchemaVersion,
        createdAt: Date = .now,
        library: Library,
        scanResult: Result,
        albumNameEnhancement: AlbumNameEnhancement?
    ) {
        self.schemaVersion = schemaVersion
        self.createdAt = createdAt
        self.library = library
        self.scanResult = scanResult
        self.albumNameEnhancement = albumNameEnhancement
    }
}

extension ScanSnapshot {
    struct Library: Codable, Equatable, Sendable {
        let id: UUID
        let displayName: String
        let rootPath: String
        let role: LibraryRole

        nonisolated init(library: LibraryRecord) {
            id = library.id
            displayName = library.displayName
            rootPath = URL(fileURLWithPath: library.rootPath, isDirectory: true).standardizedFileURL.path
            role = library.role
        }
    }

    struct Result: Codable, Equatable, Sendable {
        let albums: [Album]
        let looseAudioPaths: [String]

        nonisolated init(result: LibraryScanResult) {
            albums = result.albums.map(Album.init(album:))
            looseAudioPaths = result.looseAudioPaths
        }

        nonisolated func makeLibraryScanResult() throws -> LibraryScanResult {
            LibraryScanResult(
                albums: try albums.map { try $0.makeAlbumScanRecord() },
                looseAudioPaths: looseAudioPaths
            )
        }
    }

    struct Album: Codable, Equatable, Sendable {
        let folderPath: String
        let artistName: String
        let albumName: String
        let audioFiles: [AudioFile]
        let displayedCover: Cover?
        let issues: [Issue]

        nonisolated init(album: AlbumScanRecord) {
            folderPath = album.folderURL.standardizedFileURL.path
            artistName = album.artistName
            albumName = album.albumName
            audioFiles = album.audioFiles.map(AudioFile.init(audioFile:))
            displayedCover = album.displayedCover.map(Cover.init(cover:))
            issues = album.issues.map(Issue.init(issue:))
        }

        nonisolated func makeAlbumScanRecord() throws -> AlbumScanRecord {
            AlbumScanRecord(
                folderURL: URL(fileURLWithPath: folderPath, isDirectory: true),
                artistName: artistName,
                albumName: albumName,
                audioFiles: try audioFiles.map { try $0.makeAudioFileRecord() },
                displayedCover: displayedCover?.makeCoverCandidate(),
                issues: try issues.map { try $0.makeAlbumScanIssue() }
            )
        }
    }

    struct AudioFile: Codable, Equatable, Sendable {
        let path: String
        let relativePath: String
        let format: String
        let metadata: Metadata?
        let readError: String?

        nonisolated init(audioFile: AudioFileRecord) {
            path = audioFile.url.standardizedFileURL.path
            relativePath = audioFile.relativePath
            format = audioFile.format
            metadata = audioFile.metadata.map(Metadata.init(metadata:))
            readError = audioFile.readError
        }

        nonisolated func makeAudioFileRecord() throws -> AudioFileRecord {
            AudioFileRecord(
                url: URL(fileURLWithPath: path),
                relativePath: relativePath,
                format: format,
                metadata: metadata?.makeAudioMetadata(),
                readError: readError
            )
        }
    }

    struct Metadata: Codable, Equatable, Sendable {
        let title: String?
        let artist: String?
        let albumArtist: String?
        let album: String?
        let discNumber: Int?
        let trackNumber: Int?
        let durationSeconds: Int?
        let embeddedArtworkPath: String?

        nonisolated init(metadata: AudioMetadata) {
            title = metadata.title
            artist = metadata.artist
            albumArtist = metadata.albumArtist
            album = metadata.album
            discNumber = metadata.discNumber
            trackNumber = metadata.trackNumber
            durationSeconds = metadata.durationSeconds
            embeddedArtworkPath = metadata.embeddedArtworkURL?.standardizedFileURL.path
        }

        nonisolated func makeAudioMetadata() -> AudioMetadata {
            AudioMetadata(
                title: title,
                artist: artist,
                albumArtist: albumArtist,
                album: album,
                discNumber: discNumber,
                trackNumber: trackNumber,
                durationSeconds: durationSeconds,
                embeddedArtworkURL: embeddedArtworkPath.map(URL.init(fileURLWithPath:))
            )
        }
    }

    struct Cover: Codable, Equatable, Sendable {
        let path: String
        let previewPath: String?
        let relativePath: String
        let namePriority: Int
        let depth: Int
        let source: Source

        nonisolated init(cover: CoverCandidate) {
            path = cover.url.standardizedFileURL.path
            previewPath = cover.previewURL?.standardizedFileURL.path
            relativePath = cover.relativePath
            namePriority = cover.namePriority
            depth = cover.depth
            source = Source(coverSource: cover.source)
        }

        nonisolated func makeCoverCandidate() -> CoverCandidate {
            CoverCandidate(
                url: URL(fileURLWithPath: path),
                previewURL: previewPath.map(URL.init(fileURLWithPath:)),
                relativePath: relativePath,
                namePriority: namePriority,
                depth: depth,
                source: source.makeCoverSource()
            )
        }
    }

    enum Source: String, Codable, Equatable, Sendable {
        case file
        case embeddedArtwork

        nonisolated init(coverSource: CoverSource) {
            switch coverSource {
            case .file:
                self = .file
            case .embeddedArtwork:
                self = .embeddedArtwork
            }
        }

        nonisolated func makeCoverSource() -> CoverSource {
            switch self {
            case .file:
                .file
            case .embeddedArtwork:
                .embeddedArtwork
            }
        }
    }

    struct Issue: Codable, Equatable, Sendable {
        enum Kind: String, Codable, Sendable {
            case singleFileNeedsConfirmation
            case metadataReadFailed
            case invalidNamedCovers
            case uncertainAlbumBoundary
            case trackNamedAudioFiles
        }

        let kind: Kind
        let hasCue: Bool?
        let paths: [String]?
        let reason: String?

        nonisolated init(issue: AlbumScanIssue) {
            switch issue {
            case .singleFileNeedsConfirmation(let hasCue):
                kind = .singleFileNeedsConfirmation
                self.hasCue = hasCue
                paths = nil
                reason = nil
            case .metadataReadFailed(let paths):
                kind = .metadataReadFailed
                hasCue = nil
                self.paths = paths
                reason = nil
            case .invalidNamedCovers(let paths):
                kind = .invalidNamedCovers
                hasCue = nil
                self.paths = paths
                reason = nil
            case .uncertainAlbumBoundary(let reason):
                kind = .uncertainAlbumBoundary
                hasCue = nil
                paths = nil
                self.reason = reason
            case .trackNamedAudioFiles(let paths):
                kind = .trackNamedAudioFiles
                hasCue = nil
                self.paths = paths
                reason = nil
            }
        }

        nonisolated func makeAlbumScanIssue() throws -> AlbumScanIssue {
            switch kind {
            case .singleFileNeedsConfirmation:
                guard let hasCue else { throw ScanSnapshotError.missingIssuePayload(kind.rawValue) }
                return .singleFileNeedsConfirmation(hasCue: hasCue)
            case .metadataReadFailed:
                return .metadataReadFailed(paths: paths ?? [])
            case .invalidNamedCovers:
                return .invalidNamedCovers(paths: paths ?? [])
            case .uncertainAlbumBoundary:
                guard let reason else { throw ScanSnapshotError.missingIssuePayload(kind.rawValue) }
                return .uncertainAlbumBoundary(reason: reason)
            case .trackNamedAudioFiles:
                return .trackNamedAudioFiles(paths: paths ?? [])
            }
        }
    }

    struct AlbumNameEnhancement: Codable, Equatable, Sendable {
        let suggestionsByAlbumPath: [String: Suggestion]
        let status: Status?

        nonisolated init(
            suggestionsByAlbumID: [AlbumScanRecord.ID: AlbumNameSuggestion],
            status: AlbumNameEnhancementStatus?
        ) {
            suggestionsByAlbumPath = suggestionsByAlbumID.mapValues(Suggestion.init(suggestion:))
            self.status = status.map(Status.init(status:))
        }

        nonisolated func makeSuggestionsByAlbumID() -> [AlbumScanRecord.ID: AlbumNameSuggestion] {
            suggestionsByAlbumPath.mapValues { $0.makeAlbumNameSuggestion() }
        }
    }

    struct Suggestion: Codable, Equatable, Sendable {
        let artistName: String
        let albumName: String

        nonisolated init(suggestion: AlbumNameSuggestion) {
            artistName = suggestion.artistName
            albumName = suggestion.albumName
        }

        nonisolated func makeAlbumNameSuggestion() -> AlbumNameSuggestion {
            AlbumNameSuggestion(artistName: artistName, albumName: albumName)
        }
    }

    struct Status: Codable, Equatable, Sendable {
        let isRunning: Bool
        let lastErrorMessage: String?

        nonisolated init(status: AlbumNameEnhancementStatus) {
            isRunning = status.isRunning
            lastErrorMessage = status.lastErrorMessage
        }

        nonisolated func makeAlbumNameEnhancementStatusForLoadedSnapshot() -> AlbumNameEnhancementStatus {
            AlbumNameEnhancementStatus(
                isRunning: false,
                lastErrorMessage: lastErrorMessage
            )
        }
    }
}

enum ScanSnapshotError: LocalizedError, Sendable {
    case missingIssuePayload(String)

    var errorDescription: String? {
        switch self {
        case .missingIssuePayload(let kind):
            "扫描快照中的异常记录缺少必要字段：\(kind)"
        }
    }
}
