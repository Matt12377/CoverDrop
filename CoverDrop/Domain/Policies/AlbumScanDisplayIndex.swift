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

nonisolated final class AlbumScanDisplayIndex: @unchecked Sendable {
    typealias PresentationBuilder = (AlbumScanRecord, UInt64) -> AlbumCoverCardPresentation

    private struct SnapshotKey: Hashable {
        let revision: UInt64
        let filter: String
        let normalizedQuery: String
    }

    private var result: LibraryScanResult
    private(set) var stats: AlbumScanResultStats
    private(set) var failedAlbumIDs: Set<AlbumScanRecord.ID>

    private var albumsByID: [AlbumScanRecord.ID: AlbumScanRecord]
    private var albumsByFilter: [AlbumScanResultFilter: [AlbumScanRecord]]
    private var albumIndexByFilter: [AlbumScanResultFilter: [AlbumScanRecord.ID: Int]]
    private var searchTextByAlbumID: [AlbumScanRecord.ID: String]
    private var albumIDsBySearchCharacter: [Character: Set<AlbumScanRecord.ID>]
    private var albumOrderByID: [AlbumScanRecord.ID: Int]
    private var presentationsByID: [AlbumScanRecord.ID: AlbumCoverCardPresentation]
    private var coverWallSnapshots: [SnapshotKey: AlbumCoverWallSnapshot]
    private var revision: UInt64
    private var nextContentRevision: UInt64
    private let makePresentation: PresentationBuilder

    init(
        result: LibraryScanResult,
        failedAlbumIDs: Set<AlbumScanRecord.ID> = [],
        displayNames: ((AlbumScanRecord) -> (artistName: String, albumName: String))? = nil,
        makePresentation: PresentationBuilder? = nil
    ) {
        let buildPresentation = makePresentation ?? { album, contentRevision in
            Self.defaultPresentation(
                for: album,
                contentRevision: contentRevision,
                displayNames: displayNames
            )
        }
        self.result = result
        self.failedAlbumIDs = failedAlbumIDs
        self.makePresentation = buildPresentation

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
        var presentationsByID: [AlbumScanRecord.ID: AlbumCoverCardPresentation] = [:]
        presentationsByID.reserveCapacity(result.albums.count)
        var contentRevision: UInt64 = 0

        let performanceSpan = CoverDropPerformanceLog.begin(
            CoverDropPerformanceOperation.buildCoverWall,
            context: ["albumCount": String(result.albums.count), "mode": "initial"]
        )

        for album in result.albums {
            if Self.hasDisplayedCover(album) {
                albumsWithCover += 1
            }
            if album.needsAttention {
                albumsNeedingAttention += 1
            }

            for filter in AlbumScanResultFilter.allCases where Self.matches(filter: filter, album: album, failedAlbumIDs: failedAlbumIDs) {
                albumsByFilter[filter, default: []].append(album)
            }

            contentRevision &+= 1
            let presentation = buildPresentation(album, contentRevision)
            presentationsByID[album.id] = presentation
            let values = [
                album.albumName,
                album.artistName,
                album.folderURL.path,
                presentation.displayAlbumName,
                presentation.displayArtistName
            ]
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
        self.presentationsByID = presentationsByID
        coverWallSnapshots = [:]
        revision = 1
        nextContentRevision = contentRevision
        stats = AlbumScanResultStats(
            albumCount: result.albums.count,
            albumsWithCover: albumsWithCover,
            albumsNeedingAttention: albumsNeedingAttention,
            looseAudioCount: result.looseAudioPaths.count
        )
        performanceSpan?.finish()
    }

    func album(id albumID: AlbumScanRecord.ID) -> AlbumScanRecord? {
        albumsByID[albumID]
    }

    func presentation(id albumID: AlbumScanRecord.ID) -> AlbumCoverCardPresentation? {
        presentationsByID[albumID]
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

    func coverWallSnapshot(
        filter: AlbumScanResultFilter,
        query: String
    ) -> AlbumCoverWallSnapshot {
        let normalizedQuery = Self.normalizedSearchText([query])
        let key = SnapshotKey(
            revision: revision,
            filter: filter.rawValue,
            normalizedQuery: normalizedQuery
        )
        if let cached = coverWallSnapshots[key] {
            return cached
        }

        let performanceSpan = CoverDropPerformanceLog.begin(
            CoverDropPerformanceOperation.buildCoverWall,
            context: ["mode": "snapshot", "query": normalizedQuery]
        )
        let cards = albums(filter: filter, query: query).compactMap { album in
            presentationsByID[album.id]
        }
        let snapshot = AlbumCoverWallSnapshot(
            revision: revision,
            filter: filter,
            normalizedQuery: normalizedQuery,
            cards: cards
        )
        coverWallSnapshots[key] = snapshot
        performanceSpan?.finish(context: ["albumCount": String(cards.count)])
        return snapshot
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
        makePresentation replacementPresentationBuilder: PresentationBuilder? = nil,
        displayNames: ((AlbumScanRecord) -> (artistName: String, albumName: String))? = nil
    ) -> AlbumScanDisplayIndex {
        guard !refreshedAlbums.isEmpty else { return self }
        let presentationBuilder = replacementPresentationBuilder ?? makePresentation
        let replacedAlbums = refreshedAlbums.filter { albumsByID[$0.id] != nil }
        var albumsWithCover = stats.albumsWithCover
        var albumsNeedingAttention = stats.albumsNeedingAttention
        var didReplaceAlbum = false
        for album in replacedAlbums {
            guard let oldAlbum = albumsByID[album.id] else { continue }
            didReplaceAlbum = true
            if !Self.hasDisplayedCover(oldAlbum), Self.hasDisplayedCover(album) {
                albumsWithCover += 1
            } else if Self.hasDisplayedCover(oldAlbum), !Self.hasDisplayedCover(album) {
                albumsWithCover -= 1
            }
            if !oldAlbum.needsAttention, album.needsAttention {
                albumsNeedingAttention += 1
            } else if oldAlbum.needsAttention, !album.needsAttention {
                albumsNeedingAttention -= 1
            }
            albumsByID[album.id] = album
            nextContentRevision &+= 1
            presentationsByID[album.id] = presentationBuilder(album, nextContentRevision)
        }

        for album in replacedAlbums {
            updateSearchText(for: album, displayNames: displayNames)
        }

        for filter in AlbumScanResultFilter.allCases where filter != .looseAudio {
            updateBucket(for: filter, albums: replacedAlbums)
        }

        stats = AlbumScanResultStats(
            albumCount: stats.albumCount,
            albumsWithCover: albumsWithCover,
            albumsNeedingAttention: albumsNeedingAttention,
            looseAudioCount: stats.looseAudioCount
        )
        if didReplaceAlbum {
            revision &+= 1
            coverWallSnapshots.removeAll(keepingCapacity: true)
        }
        return self
    }

    func updatingNameEnhancement(
        for albumID: AlbumScanRecord.ID,
        failedAlbumIDs: Set<AlbumScanRecord.ID>,
        makePresentation replacementPresentationBuilder: PresentationBuilder? = nil,
        displayNames: ((AlbumScanRecord) -> (artistName: String, albumName: String))? = nil
    ) -> AlbumScanDisplayIndex {
        self.failedAlbumIDs = failedAlbumIDs
        guard let album = albumsByID[albumID] else { return self }

        nextContentRevision &+= 1
        let presentationBuilder = replacementPresentationBuilder ?? makePresentation
        presentationsByID[album.id] = presentationBuilder(album, nextContentRevision)
        updateSearchText(for: album, displayNames: displayNames)
        updateBucket(for: .nameEnhancementFailed, album: album)
        revision &+= 1
        coverWallSnapshots.removeAll(keepingCapacity: true)
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
        } else if let presentation = presentationsByID[album.id] {
            values.append(presentation.displayAlbumName)
            values.append(presentation.displayArtistName)
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
        let newMatches = Self.matches(
            filter: filter,
            album: album,
            failedAlbumIDs: failedAlbumIDs
        )

        if let oldIndex {
            if newMatches {
                bucket[oldIndex] = album
            } else {
                bucket.remove(at: oldIndex)
                bucketIndexes[album.id] = nil
                refreshBucketIndexes(
                    &bucketIndexes,
                    bucket: bucket,
                    startingAt: oldIndex
                )
            }
        } else if newMatches {
            let insertionIndex = insertionIndex(for: album.id, in: bucket)
            bucket.insert(album, at: insertionIndex)
            refreshBucketIndexes(
                &bucketIndexes,
                bucket: bucket,
                startingAt: insertionIndex
            )
        }

        albumsByFilter[filter] = bucket
        albumIndexByFilter[filter] = bucketIndexes
    }

    private func updateBucket(
        for filter: AlbumScanResultFilter,
        albums: [AlbumScanRecord]
    ) {
        guard !albums.isEmpty else { return }
        if albums.count == 1, let album = albums.first {
            updateBucket(for: filter, album: album)
            return
        }
        var bucket = albumsByFilter[filter] ?? []
        let replacementsByID = Dictionary(
            uniqueKeysWithValues: albums.map { ($0.id, $0) }
        )

        for index in bucket.indices.reversed() {
            guard let replacement = replacementsByID[bucket[index].id] else { continue }
            if Self.matches(
                filter: filter,
                album: replacement,
                failedAlbumIDs: failedAlbumIDs
            ) {
                bucket[index] = replacement
            } else {
                bucket.remove(at: index)
            }
        }

        var existingAlbumIDs = Set(bucket.map(\.id))
        for album in albums where !existingAlbumIDs.contains(album.id) {
            guard Self.matches(
                filter: filter,
                album: album,
                failedAlbumIDs: failedAlbumIDs
            ) else {
                continue
            }
            bucket.insert(album, at: insertionIndex(for: album.id, in: bucket))
            existingAlbumIDs.insert(album.id)
        }

        albumsByFilter[filter] = bucket
        albumIndexByFilter[filter] = Dictionary(
            uniqueKeysWithValues: bucket.enumerated().map { ($0.element.id, $0.offset) }
        )
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
            !hasDisplayedCover(album)
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
            hasDisplayedCover(album)
        case .nameEnhancementFailed:
            failedAlbumIDs.contains(album.id)
        case .looseAudio:
            false
        }
    }

    private static func hasDisplayedCover(_ album: AlbumScanRecord) -> Bool {
        switch album.displayedCover {
        case .some:
            true
        case .none:
            false
        }
    }

    static func canSplitSingleFileCue(_ album: AlbumScanRecord) -> Bool {
        guard album.audioFiles.count == 1,
              !album.cueSheets.isEmpty else {
            return false
        }
        return album.issues.contains {
            if case .singleFileNeedsConfirmation(let hasCue) = $0 {
                return hasCue
            }
            return false
        }
    }

    private static func defaultPresentation(
        for album: AlbumScanRecord,
        contentRevision: UInt64,
        displayNames: ((AlbumScanRecord) -> (artistName: String, albumName: String))?
    ) -> AlbumCoverCardPresentation {
        let names = displayNames?(album) ?? (
            artistName: album.artistName,
            albumName: album.albumName
        )
        let issueHelp = album.issues.map(\.displayName).joined(separator: "\n")
        return AlbumCoverCardPresentation(
            id: album.id,
            folderURL: album.folderURL,
            displayArtistName: names.artistName,
            displayAlbumName: names.albumName,
            formatTags: Array(Set(album.audioFiles.map { $0.format.uppercased() }))
                .sorted()
                .prefix(2)
                .map { $0 },
            coverURL: album.displayedCover?.displayURL,
            contentRevision: contentRevision,
            coverSourceName: album.displayedCover?.source.displayName,
            needsAttention: album.needsAttention,
            issueHelp: issueHelp.isEmpty ? nil : issueHelp,
            canSplitWithXLD: canSplitSingleFileCue(album),
            hasEnhancedName: false,
            enhancementErrorMessage: nil
        )
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
