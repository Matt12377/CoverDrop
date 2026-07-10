import Foundation

protocol AlbumFolderOpening: Sendable {
    nonisolated func openAlbumFolder(_ folderURL: URL) async throws
}

protocol CueSheetSplitting: Sendable {
    nonisolated func splitCueSheet(_ cueSheetURL: URL) async throws
}

struct DisabledAlbumFolderOpener: AlbumFolderOpening {
    nonisolated func openAlbumFolder(_ folderURL: URL) async throws {
        throw DisabledAlbumFolderOpenerError()
    }
}

struct DisabledCueSheetSplitter: CueSheetSplitting {
    nonisolated func splitCueSheet(_ cueSheetURL: URL) async throws {
        throw DisabledCueSheetSplitterError()
    }
}

private struct DisabledAlbumFolderOpenerError: LocalizedError, Sendable {
    var errorDescription: String? {
        "Finder 打开服务尚未启用。"
    }
}

private struct DisabledCueSheetSplitterError: LocalizedError, Sendable {
    var errorDescription: String? {
        "XLD 分轨服务尚未启用。"
    }
}
