import Foundation

enum AlbumScanResultFilter: String, CaseIterable, Identifiable, Sendable {
    case all
    case missingCover
    case needsAttention
    case withCover
    case looseAudio

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .all:
            "全部"
        case .missingCover:
            "缺封面"
        case .needsAttention:
            "需确认"
        case .withCover:
            "已有封面"
        case .looseAudio:
            "散落音频"
        }
    }
}

struct AlbumScanResultFiltering: Sendable {
    static func albums(
        in result: LibraryScanResult,
        filter: AlbumScanResultFilter,
        query: String
    ) -> [AlbumScanRecord] {
        guard filter != .looseAudio else { return [] }
        let normalizedQuery = query.trimmingCharacters(in: .whitespacesAndNewlines)

        return result.albums.filter { album in
            matches(filter: filter, album: album) && matches(query: normalizedQuery, album: album)
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

    private static func matches(filter: AlbumScanResultFilter, album: AlbumScanRecord) -> Bool {
        switch filter {
        case .all:
            true
        case .missingCover:
            album.displayedCover == nil
        case .needsAttention:
            album.needsAttention
        case .withCover:
            album.displayedCover != nil
        case .looseAudio:
            false
        }
    }

    private static func matches(query: String, album: AlbumScanRecord) -> Bool {
        guard !query.isEmpty else { return true }
        return [
            album.albumName,
            album.artistName,
            album.folderURL.path
        ].contains { value in
            value.range(
                of: query,
                options: [.caseInsensitive, .diacriticInsensitive]
            ) != nil
        }
    }
}
