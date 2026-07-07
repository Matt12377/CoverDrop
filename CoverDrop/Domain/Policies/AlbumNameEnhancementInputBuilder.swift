import Foundation

enum AlbumNameEnhancementInputBuilder {
    static func makeInput(
        for album: AlbumScanRecord,
        libraryRootPath: String?,
        maxTracks: Int
    ) -> AlbumNameEnhancementInput {
        let tracks = album.audioFiles
            .prefix(Swift.max(0, maxTracks))
            .map { audioFile in
                AlbumNameEnhancementInput.Track(
                    relativePath: audioFile.relativePath,
                    title: audioFile.metadata?.title,
                    artist: audioFile.metadata?.artist,
                    albumArtist: audioFile.metadata?.albumArtist,
                    album: audioFile.metadata?.album,
                    discNumber: audioFile.metadata?.discNumber,
                    trackNumber: audioFile.metadata?.trackNumber
                )
            }

        return AlbumNameEnhancementInput(
            originalArtistName: album.artistName,
            originalAlbumName: album.albumName,
            albumRelativePath: album.folderURL.relativePath(fromLibraryRootPath: libraryRootPath),
            albumFolderName: album.folderURL.lastPathComponent,
            parentFolderName: album.folderURL.deletingLastPathComponent().lastPathComponent,
            audioFiles: Array(tracks)
        )
    }
}

private extension URL {
    func relativePath(fromLibraryRootPath libraryRootPath: String?) -> String {
        let trimmedRootPath = libraryRootPath?.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let trimmedRootPath, !trimmedRootPath.isEmpty else {
            return meaningfulTailPath()
        }

        let rootURL = URL(fileURLWithPath: trimmedRootPath, isDirectory: true).standardizedFileURL
        let albumURL = standardizedFileURL
        let rootPath = rootURL.path
        let albumPath = albumURL.path

        if albumPath == rootPath {
            return albumURL.lastPathComponent
        }

        let prefix = rootPath.hasSuffix("/") ? rootPath : rootPath + "/"
        if albumPath.hasPrefix(prefix) {
            return String(albumPath.dropFirst(prefix.count))
        }

        return meaningfulTailPath()
    }

    func meaningfulTailPath() -> String {
        let components = standardizedFileURL.pathComponents.filter { $0 != "/" }
        guard !components.isEmpty else { return lastPathComponent }
        if components.count >= 2 {
            return components.suffix(2).joined(separator: "/")
        }
        return lastPathComponent
    }
}
