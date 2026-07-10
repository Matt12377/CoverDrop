import Foundation

enum AlbumScanResultFilter: String, CaseIterable, Identifiable, Sendable {
    case all
    case missingCover
    case singleFileUnsplit
    case metadataReadFailed
    case trackNamedAudioFiles
    case withCover
    case nameEnhancementFailed
    case looseAudio

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .all:
            "全部"
        case .missingCover:
            "缺封面"
        case .singleFileUnsplit:
            "未分轨"
        case .metadataReadFailed:
            "标签异常"
        case .trackNamedAudioFiles:
            "track音轨"
        case .withCover:
            "已有封面"
        case .nameEnhancementFailed:
            "解析失败"
        case .looseAudio:
            "散落音频"
        }
    }
}

struct AlbumScanResultFiltering: Sendable {
    static func albums(
        in result: LibraryScanResult,
        filter: AlbumScanResultFilter,
        query: String,
        failedAlbumIDs: Set<AlbumScanRecord.ID> = [],
        displayNames: ((AlbumScanRecord) -> (artistName: String, albumName: String))? = nil
    ) -> [AlbumScanRecord] {
        guard filter != .looseAudio else { return [] }
        let normalizedQuery = query.trimmingCharacters(in: .whitespacesAndNewlines)

        return result.albums.filter { album in
            matches(filter: filter, album: album, failedAlbumIDs: failedAlbumIDs) && matches(
                query: normalizedQuery,
                album: album,
                displayNames: displayNames
            )
        }
    }

    static func looseAudioPaths(
        in result: LibraryScanResult,
        filter: AlbumScanResultFilter,
        query: String
    ) -> [String] {
        guard filter == .looseAudio else { return [] }
        let normalizedQuery = query.trimmingCharacters(in: .whitespacesAndNewlines)

        guard !normalizedQuery.isEmpty else { return result.looseAudioPaths }
        return result.looseAudioPaths.filter {
            $0.range(
                of: normalizedQuery,
                options: [.caseInsensitive, .diacriticInsensitive]
            ) != nil
        }
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
            hasSingleFileUnsplitIssue(album)
        case .metadataReadFailed:
            hasIssue(album) {
                if case .metadataReadFailed = $0 { return true }
                return false
            }
        case .trackNamedAudioFiles:
            hasIssue(album) {
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

    private static func hasIssue(
        _ album: AlbumScanRecord,
        matching predicate: (AlbumScanIssue) -> Bool
    ) -> Bool {
        album.issues.contains(where: predicate)
    }

    private static func hasSingleFileUnsplitIssue(_ album: AlbumScanRecord) -> Bool {
        album.issues.contains { issue in
            if case .singleFileNeedsConfirmation(let hasCue) = issue {
                return hasCue
            }
            return false
        }
    }

    private static func matches(
        query: String,
        album: AlbumScanRecord,
        displayNames: ((AlbumScanRecord) -> (artistName: String, albumName: String))?
    ) -> Bool {
        guard !query.isEmpty else { return true }
        var values = [
            album.albumName,
            album.artistName,
            album.folderURL.path
        ]

        if let displayNames {
            let names = displayNames(album)
            values.insert(names.albumName, at: 0)
            values.insert(names.artistName, at: 0)
        }

        return values.contains { value in
            value.range(
                of: query,
                options: [.caseInsensitive, .diacriticInsensitive]
            ) != nil
        }
    }
}
