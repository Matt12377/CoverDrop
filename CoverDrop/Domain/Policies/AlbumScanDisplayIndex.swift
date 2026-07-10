import Foundation

struct AlbumScanResultStats: Equatable, Sendable {
    let albumCount: Int
    let albumsWithCover: Int
    let albumsNeedingAttention: Int
    let looseAudioCount: Int

    var albumsMissingCover: Int {
        albumCount - albumsWithCover
    }
}

final class AlbumScanDisplayIndex: @unchecked Sendable {
    private var result: LibraryScanResult
    private(set) var stats: AlbumScanResultStats
    private(set) var failedAlbumIDs: Set<AlbumScanRecord.ID>

    private var albumsByID: [AlbumScanRecord.ID: AlbumScanRecord]
    private var albumsByFilter: [AlbumScanResultFilter: [AlbumScanRecord]]
    private var albumIndexByFilter: [AlbumScanResultFilter: [AlbumScanRecord.ID: Int]]
    private var searchTextByAlbumID: [AlbumScanRecord.ID: String]
    private var albumIDsBySearchCharacter: [Character: Set<AlbumScanRecord.ID>]
    private var albumOrderByID: [AlbumScanRecord.ID: Int]

    private init(
        result: LibraryScanResult,
        stats: AlbumScanResultStats,
        failedAlbumIDs: Set<AlbumScanRecord.ID>,
        albumsByID: [AlbumScanRecord.ID: AlbumScanRecord],
        albumsByFilter: [AlbumScanResultFilter: [AlbumScanRecord]],
        albumIndexByFilter: [AlbumScanResultFilter: [AlbumScanRecord.ID: Int]],
        searchTextByAlbumID: [AlbumScanRecord.ID: String],
        albumIDsBySearchCharacter: [Character: Set<AlbumScanRecord.ID>],
        albumOrderByID: [AlbumScanRecord.ID: Int]
    ) {
        self.result = result
        self.stats = stats
        self.failedAlbumIDs = failedAlbumIDs
        self.albumsByID = albumsByID
        self.albumsByFilter = albumsByFilter
        self.albumIndexByFilter = albumIndexByFilter
        self.searchTextByAlbumID = searchTextByAlbumID
        self.albumIDsBySearchCharacter = albumIDsBySearchCharacter
        self.albumOrderByID = albumOrderByID
    }

    init(
        result: LibraryScanResult,
        failedAlbumIDs: Set<AlbumScanRecord.ID> = [],
        displayNames: ((AlbumScanRecord) -> (artistName: String, albumName: String))? = nil
    ) {
        self.result = result
        self.failedAlbumIDs = failedAlbumIDs

        var albumsByID: [AlbumScanRecord.ID: AlbumScanRecord] = [:]
        albumsByID.reserveCapacity(result.albums.count)
        var albumOrderByID: [AlbumScanRecord.ID: Int] = [:]
        albumOrderByID.reserveCapacity(result.albums.count)
        for (index, album) in result.albums.enumerated() {
            albumsByID[album.id] = album
            albumOrderByID[album.id] = index
        }
        self.albumsByID = albumsByID
        self.albumOrderByID = albumOrderByID

        var albumsByFilter: [AlbumScanResultFilter: [AlbumScanRecord]] = [:]
        for filter in AlbumScanResultFilter.allCases where filter != .looseAudio {
            albumsByFilter[filter] = []
            albumsByFilter[filter]?.reserveCapacity(result.albums.count)
        }

        var albumsWithCover = 0
        var albumsNeedingAttention = 0
        var searchTextByAlbumID: [AlbumScanRecord.ID: String] = [:]
        searchTextByAlbumID.reserveCapacity(result.albums.count)
        var albumIDsBySearchCharacter: [Character: Set<AlbumScanRecord.ID>] = [:]

        for album in result.albums {
            if album.displayedCover != nil {
                albumsWithCover += 1
            }
            if album.needsAttention {
                albumsNeedingAttention += 1
            }

            for filter in AlbumScanResultFilter.allCases where Self.matches(filter: filter, album: album, failedAlbumIDs: failedAlbumIDs) {
                albumsByFilter[filter, default: []].append(album)
            }

            var values = [
                album.albumName,
                album.artistName,
                album.folderURL.path
            ]
            if let displayNames {
                let names = displayNames(album)
                values.append(names.albumName)
                values.append(names.artistName)
            }
            let searchText = Self.normalizedSearchText(values)
            searchTextByAlbumID[album.id] = searchText
            for character in Set(searchText) where !character.isWhitespace {
                albumIDsBySearchCharacter[character, default: []].insert(album.id)
            }
        }

        self.albumsByFilter = albumsByFilter
        self.albumIndexByFilter = Self.makeAlbumIndexByFilter(albumsByFilter)
        self.searchTextByAlbumID = searchTextByAlbumID
        self.albumIDsBySearchCharacter = albumIDsBySearchCharacter
        stats = AlbumScanResultStats(
            albumCount: result.albums.count,
            albumsWithCover: albumsWithCover,
            albumsNeedingAttention: albumsNeedingAttention,
            looseAudioCount: result.looseAudioPaths.count
        )
    }

    func album(id albumID: AlbumScanRecord.ID) -> AlbumScanRecord? {
        albumsByID[albumID]
    }

    func albums(filter: AlbumScanResultFilter, query: String) -> [AlbumScanRecord] {
        guard filter != .looseAudio else { return [] }
        let albums = albumsByFilter[filter] ?? []
        let normalizedQuery = Self.normalizedSearchText([query])
        guard !normalizedQuery.isEmpty else { return albums }
        guard let candidateIDs = candidateAlbumIDs(for: normalizedQuery) else { return [] }

        return albums.filter { album in
            candidateIDs.contains(album.id)
                && searchTextByAlbumID[album.id]?.contains(normalizedQuery) == true
        }
    }

    func looseAudioPaths(filter: AlbumScanResultFilter, query: String) -> [String] {
        guard filter == .looseAudio else { return [] }
        let normalizedQuery = Self.normalizedSearchText([query])
        guard !normalizedQuery.isEmpty else { return result.looseAudioPaths }
        return result.looseAudioPaths.filter {
            Self.normalizedSearchText([$0]).contains(normalizedQuery)
        }
    }

    func replacingAlbums(
        _ refreshedAlbums: [AlbumScanRecord],
        displayNames: ((AlbumScanRecord) -> (artistName: String, albumName: String))? = nil
    ) -> AlbumScanDisplayIndex {
        guard !refreshedAlbums.isEmpty else { return self }
        var albumsWithCover = stats.albumsWithCover
        var albumsNeedingAttention = stats.albumsNeedingAttention
        for album in refreshedAlbums {
            guard let oldAlbum = albumsByID[album.id] else { continue }
            if oldAlbum.displayedCover == nil, album.displayedCover != nil {
                albumsWithCover += 1
            } else if oldAlbum.displayedCover != nil, album.displayedCover == nil {
                albumsWithCover -= 1
            }
            if !oldAlbum.needsAttention, album.needsAttention {
                albumsNeedingAttention += 1
            } else if oldAlbum.needsAttention, !album.needsAttention {
                albumsNeedingAttention -= 1
            }
            albumsByID[album.id] = album
        }

        for album in refreshedAlbums {
            updateSearchText(for: album, displayNames: displayNames)
        }

        for filter in AlbumScanResultFilter.allCases where filter != .looseAudio {
            for album in refreshedAlbums {
                updateBucket(for: filter, album: album)
            }
        }

        stats = AlbumScanResultStats(
            albumCount: stats.albumCount,
            albumsWithCover: albumsWithCover,
            albumsNeedingAttention: albumsNeedingAttention,
            looseAudioCount: stats.looseAudioCount
        )
        return self
    }

    func updatingNameEnhancement(
        for albumID: AlbumScanRecord.ID,
        failedAlbumIDs: Set<AlbumScanRecord.ID>,
        displayNames: ((AlbumScanRecord) -> (artistName: String, albumName: String))? = nil
    ) -> AlbumScanDisplayIndex {
        self.failedAlbumIDs = failedAlbumIDs
        guard let album = albumsByID[albumID] else { return self }

        updateSearchText(for: album, displayNames: displayNames)
        updateBucket(for: .nameEnhancementFailed, album: album)
        return self
    }

    private func updateSearchText(
        for album: AlbumScanRecord,
        displayNames: ((AlbumScanRecord) -> (artistName: String, albumName: String))?
    ) {
        if let oldText = searchTextByAlbumID[album.id] {
            for character in Set(oldText) where !character.isWhitespace {
                albumIDsBySearchCharacter[character]?.remove(album.id)
                if albumIDsBySearchCharacter[character]?.isEmpty == true {
                    albumIDsBySearchCharacter[character] = nil
                }
            }
        }

        var values = [
            album.albumName,
            album.artistName,
            album.folderURL.path
        ]
        if let displayNames {
            let names = displayNames(album)
            values.append(names.albumName)
            values.append(names.artistName)
        }
        let searchText = Self.normalizedSearchText(values)
        searchTextByAlbumID[album.id] = searchText
        for character in Set(searchText) where !character.isWhitespace {
            albumIDsBySearchCharacter[character, default: []].insert(album.id)
        }
    }

    private func updateBucket(for filter: AlbumScanResultFilter, album: AlbumScanRecord) {
        var bucket = albumsByFilter[filter] ?? []
        var bucketIndexes = albumIndexByFilter[filter] ?? [:]
        let oldIndex = bucketIndexes[album.id]
        let newMatches = Self.matches(filter: filter, album: album, failedAlbumIDs: failedAlbumIDs)

        if let oldIndex {
            if newMatches {
                bucket[oldIndex] = album
            } else {
                bucket.remove(at: oldIndex)
                bucketIndexes[album.id] = nil
                refreshBucketIndexes(&bucketIndexes, bucket: bucket, startingAt: oldIndex)
            }
        } else if newMatches {
            let insertionIndex = insertionIndex(for: album.id, in: bucket)
            bucket.insert(album, at: insertionIndex)
            refreshBucketIndexes(&bucketIndexes, bucket: bucket, startingAt: insertionIndex)
        }

        albumsByFilter[filter] = bucket
        albumIndexByFilter[filter] = bucketIndexes
    }

    private func refreshBucketIndexes(
        _ indexes: inout [AlbumScanRecord.ID: Int],
        bucket: [AlbumScanRecord],
        startingAt startIndex: Int
    ) {
        guard startIndex < bucket.count else { return }
        for index in startIndex..<bucket.count {
            indexes[bucket[index].id] = index
        }
    }

    private func insertionIndex(
        for albumID: AlbumScanRecord.ID,
        in bucket: [AlbumScanRecord]
    ) -> Int {
        let order = albumOrderByID[albumID] ?? Int.max
        var lowerBound = 0
        var upperBound = bucket.count
        while lowerBound < upperBound {
            let middle = (lowerBound + upperBound) / 2
            let middleOrder = albumOrderByID[bucket[middle].id] ?? Int.max
            if middleOrder < order {
                lowerBound = middle + 1
            } else {
                upperBound = middle
            }
        }
        return lowerBound
    }

    private static func matches(
        filter: AlbumScanResultFilter,
        album: AlbumScanRecord,
        failedAlbumIDs: Set<AlbumScanRecord.ID>
    ) -> Bool {
        switch filter {
        case .all:
            true
        case .missingCover:
            album.displayedCover == nil
        case .singleFileUnsplit:
            canSplitSingleFileCue(album)
        case .metadataReadFailed:
            album.issues.contains {
                if case .metadataReadFailed = $0 { return true }
                return false
            }
        case .trackNamedAudioFiles:
            album.issues.contains {
                if case .trackNamedAudioFiles = $0 { return true }
                return false
            }
        case .withCover:
            album.displayedCover != nil
        case .nameEnhancementFailed:
            failedAlbumIDs.contains(album.id)
        case .looseAudio:
            false
        }
    }

    private static func canSplitSingleFileCue(_ album: AlbumScanRecord) -> Bool {
        album.issues.contains {
            if case .singleFileNeedsConfirmation(let hasCue) = $0 {
                return hasCue
            }
            return false
        }
    }

    private static func normalizedSearchText(_ values: [String]) -> String {
        values
            .joined(separator: "\n")
            .folding(options: [.caseInsensitive, .diacriticInsensitive, .widthInsensitive], locale: nil)
            .lowercased()
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func makeAlbumIndexByFilter(
        _ albumsByFilter: [AlbumScanResultFilter: [AlbumScanRecord]]
    ) -> [AlbumScanResultFilter: [AlbumScanRecord.ID: Int]] {
        var indexes: [AlbumScanResultFilter: [AlbumScanRecord.ID: Int]] = [:]
        for (filter, albums) in albumsByFilter {
            indexes[filter] = Dictionary(uniqueKeysWithValues: albums.enumerated().map { index, album in
                (album.id, index)
            })
        }
        return indexes
    }

    private func candidateAlbumIDs(for normalizedQuery: String) -> Set<AlbumScanRecord.ID>? {
        var bestCandidateIDs: Set<AlbumScanRecord.ID>?
        for character in Set(normalizedQuery) where !character.isWhitespace {
            guard let ids = albumIDsBySearchCharacter[character] else {
                return nil
            }
            let bestCount = bestCandidateIDs?.count ?? Int.max
            if ids.count < bestCount {
                bestCandidateIDs = ids
            }
        }
        return bestCandidateIDs ?? Set(albumsByID.keys)
    }
}
