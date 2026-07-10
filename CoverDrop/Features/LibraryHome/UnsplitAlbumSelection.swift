import Foundation

struct UnsplitAlbumSelection: Equatable, Sendable {
    private(set) var selectedAlbumIDs: Set<AlbumScanRecord.ID> = []

    var isEmpty: Bool {
        selectedAlbumIDs.isEmpty
    }

    mutating func toggle(_ albumID: AlbumScanRecord.ID) {
        if selectedAlbumIDs.contains(albumID) {
            selectedAlbumIDs.remove(albumID)
        } else {
            selectedAlbumIDs.insert(albumID)
        }
    }

    mutating func select(_ albumID: AlbumScanRecord.ID) {
        selectedAlbumIDs.insert(albumID)
    }

    mutating func deselect(_ albumID: AlbumScanRecord.ID) {
        selectedAlbumIDs.remove(albumID)
    }

    mutating func clear() {
        selectedAlbumIDs.removeAll()
    }

    mutating func selectAllSplitCandidates(in albums: [AlbumScanRecord]) {
        selectedAlbumIDs = Set(albums.filter(Self.canSplitWithXLD).map(\.id))
    }

    static func canSplitWithXLD(_ album: AlbumScanRecord) -> Bool {
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
}
