import Foundation

struct ScanSnapshotLoadProgress: Equatable, Sendable {
    enum Phase: Equatable, Sendable {
        case locating
        case reading
        case converting

        var displayName: String {
            switch self {
            case .locating:
                "正在查找历史快照"
            case .reading:
                "正在读取历史快照"
            case .converting:
                "正在加载专辑"
            }
        }
    }

    let phase: Phase
    let completedAlbums: Int
    let totalAlbums: Int?

    var albumProgressFraction: Double? {
        guard let totalAlbums, totalAlbums > 0 else { return nil }
        return Double(min(completedAlbums, totalAlbums)) / Double(totalAlbums)
    }

    var completedDescription: String {
        guard let totalAlbums else {
            return phase.displayName
        }
        return "已加载 \(min(completedAlbums, totalAlbums))/\(totalAlbums) 张专辑"
    }
}

struct ScanSnapshotSummary: Codable, Equatable, Sendable {
    let fileURL: URL
    let schemaVersion: Int
    let createdAt: Date
    let libraryDisplayName: String
    let libraryRootPath: String
    let libraryRole: LibraryRole
    let albumCount: Int

    var displayText: String {
        "\(libraryDisplayName) · \(createdAt.formatted(date: .numeric, time: .shortened))"
    }
}

protocol ScanSnapshotStoring: Sendable {
    func saveNewSnapshot(_ snapshot: ScanSnapshot) async throws -> ScanSnapshotSummary
    func replaceSnapshot(_ snapshot: ScanSnapshot, at fileURL: URL) async throws -> ScanSnapshotSummary
    func latestSnapshot(for library: LibraryRecord) async throws -> ScanSnapshotSummary?
    func loadSnapshot(at fileURL: URL, expectedLibrary: LibraryRecord) async throws -> ScanSnapshot
}

protocol StreamingScanSnapshotStoring: ScanSnapshotStoring {
    func loadSnapshot(
        at fileURL: URL,
        expectedLibrary: LibraryRecord,
        progress: @escaping @Sendable (ScanSnapshotLoadProgress) async -> Void
    ) async throws -> ScanSnapshot
}

protocol AlbumCoverSnapshotUpdating: Sendable {
    func updateAlbumCover(
        _ cover: ScanSnapshot.Cover?,
        forAlbumID albumID: AlbumScanRecord.ID,
        at fileURL: URL,
        expectedLibrary: LibraryRecord
    ) async throws -> ScanSnapshotSummary
}

struct DisabledScanSnapshotStore: ScanSnapshotStoring {
    func saveNewSnapshot(_ snapshot: ScanSnapshot) async throws -> ScanSnapshotSummary {
        throw DisabledScanSnapshotStoreError()
    }

    func replaceSnapshot(_ snapshot: ScanSnapshot, at fileURL: URL) async throws -> ScanSnapshotSummary {
        throw DisabledScanSnapshotStoreError()
    }

    func latestSnapshot(for library: LibraryRecord) async throws -> ScanSnapshotSummary? {
        nil
    }

    func loadSnapshot(at fileURL: URL, expectedLibrary: LibraryRecord) async throws -> ScanSnapshot {
        throw DisabledScanSnapshotStoreError()
    }
}

private struct DisabledScanSnapshotStoreError: LocalizedError, Sendable {
    var errorDescription: String? {
        "扫描快照存储尚未启用。"
    }
}
