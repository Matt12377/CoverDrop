import Foundation

struct AlbumNameSuggestion: Equatable, Sendable {
    let artistName: String
    let albumName: String

    nonisolated init(artistName: String, albumName: String) {
        self.artistName = artistName
        self.albumName = albumName
    }
}

struct AlbumNameEnhancementInput: Equatable, Sendable, Encodable {
    struct Track: Equatable, Sendable, Encodable {
        let relativePath: String
        let title: String?
        let artist: String?
        let albumArtist: String?
        let album: String?
        let discNumber: Int?
        let trackNumber: Int?

        nonisolated init(
            relativePath: String,
            title: String?,
            artist: String?,
            albumArtist: String?,
            album: String?,
            discNumber: Int?,
            trackNumber: Int?
        ) {
            self.relativePath = relativePath
            self.title = title
            self.artist = artist
            self.albumArtist = albumArtist
            self.album = album
            self.discNumber = discNumber
            self.trackNumber = trackNumber
        }
    }

    let originalArtistName: String
    let originalAlbumName: String
    let albumRelativePath: String
    let albumFolderName: String
    let parentFolderName: String
    let audioFiles: [Track]

    nonisolated init(
        originalArtistName: String,
        originalAlbumName: String,
        albumRelativePath: String,
        albumFolderName: String,
        parentFolderName: String,
        audioFiles: [Track]
    ) {
        self.originalArtistName = originalArtistName
        self.originalAlbumName = originalAlbumName
        self.albumRelativePath = albumRelativePath
        self.albumFolderName = albumFolderName
        self.parentFolderName = parentFolderName
        self.audioFiles = audioFiles
    }
}

struct AlbumNameEnhancementStatus: Equatable, Sendable {
    let isRunning: Bool
    let lastErrorMessage: String?

    nonisolated init(isRunning: Bool, lastErrorMessage: String?) {
        self.isRunning = isRunning
        self.lastErrorMessage = lastErrorMessage
    }
}

struct AlbumNameEnhancementAlbumState: Equatable, Sendable {
    let isQueued: Bool
    let isRunning: Bool
    let lastErrorMessage: String?

    nonisolated init(
        isQueued: Bool,
        isRunning: Bool,
        lastErrorMessage: String?
    ) {
        self.isQueued = isQueued
        self.isRunning = isRunning
        self.lastErrorMessage = lastErrorMessage
    }
}
