import Foundation

enum AlbumDisplayNameCleaning {
    private nonisolated static let metadataMajorityThreshold = 0.70

    nonisolated static func displayNames(
        for album: AlbumScanRecord,
        artistName: String,
        albumName: String
    ) -> (artistName: String, albumName: String) {
        let resolvedArtistName: String
        if artistName == album.artistName {
            resolvedArtistName = corroboratedArtistName(for: album) ?? artistName
        } else {
            resolvedArtistName = artistName
        }

        let resolvedAlbumName: String
        if albumName == album.albumName {
            resolvedAlbumName = corroboratedAlbumName(
                for: album,
                artistName: resolvedArtistName
            ) ?? albumName
        } else {
            resolvedAlbumName = albumName
        }

        return (
            artistName: AlbumNameCleaning.cleanArtistName(resolvedArtistName),
            albumName: AlbumNameCleaning.cleanAlbumName(
                resolvedAlbumName,
                artistName: resolvedArtistName
            )
        )
    }

    nonisolated static func clean(_ value: String) -> String {
        AlbumNameCleaning.cleanAlbumName(value, artistName: nil)
    }

    private nonisolated static func corroboratedArtistName(
        for album: AlbumScanRecord
    ) -> String? {
        let albumArtistCandidate = stableCandidate(
            from: album.audioFiles.compactMap { $0.metadata?.albumArtist },
            cleanedBy: AlbumNameCleaning.cleanArtistName,
            rejectsPlaceholder: false
        )
        if let albumArtistCandidate,
           corroborates(candidate: albumArtistCandidate, rawValue: album.artistName) {
            return albumArtistCandidate
        }

        let artistCandidate = stableCandidate(
            from: album.audioFiles.compactMap { $0.metadata?.artist },
            cleanedBy: AlbumNameCleaning.cleanArtistName,
            rejectsPlaceholder: false
        )
        if let artistCandidate,
           corroborates(candidate: artistCandidate, rawValue: album.artistName) {
            return artistCandidate
        }

        return nil
    }

    private nonisolated static func corroboratedAlbumName(
        for album: AlbumScanRecord,
        artistName: String
    ) -> String? {
        let candidate = stableCandidate(
            from: album.audioFiles.compactMap { $0.metadata?.album },
            cleanedBy: { value in
                AlbumNameCleaning.cleanAlbumName(value, artistName: artistName)
            },
            rejectsPlaceholder: true
        )

        guard let candidate,
              corroborates(candidate: candidate, rawValue: album.albumName) else {
            return nil
        }
        return candidate
    }

    private nonisolated static func stableCandidate(
        from values: [String],
        cleanedBy clean: (String) -> String,
        rejectsPlaceholder: Bool
    ) -> String? {
        let cleanedValues = values.compactMap { value -> (key: String, value: String)? in
            let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else { return nil }
            let cleaned = clean(trimmed)
            let key = AlbumNameCleaning.canonicalKey(cleaned)
            guard !key.isEmpty else { return nil }
            return (key, cleaned)
        }

        guard !cleanedValues.isEmpty else { return nil }
        let grouped = Dictionary(grouping: cleanedValues, by: \.key)
        let ranked = grouped.sorted { lhs, rhs in
            if lhs.value.count == rhs.value.count {
                return lhs.key < rhs.key
            }
            return lhs.value.count > rhs.value.count
        }
        guard let winner = ranked.first else { return nil }
        if ranked.count > 1, ranked[1].value.count == winner.value.count {
            return nil
        }

        let ratio = Double(winner.value.count) / Double(cleanedValues.count)
        guard ratio >= metadataMajorityThreshold else { return nil }
        guard let candidate = winner.value.first?.value else { return nil }
        if rejectsPlaceholder, AlbumNameCleaning.isPlaceholderAlbumName(candidate) {
            return nil
        }
        return candidate
    }

    private nonisolated static func corroborates(
        candidate: String,
        rawValue: String
    ) -> Bool {
        let candidateKey = AlbumNameCleaning.canonicalKey(candidate)
        let rawKey = AlbumNameCleaning.canonicalKey(rawValue)
        guard !candidateKey.isEmpty, !rawKey.isEmpty else { return false }
        return rawKey.contains(candidateKey)
    }
}
