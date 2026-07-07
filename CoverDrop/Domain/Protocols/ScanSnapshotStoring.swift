import Foundation

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
