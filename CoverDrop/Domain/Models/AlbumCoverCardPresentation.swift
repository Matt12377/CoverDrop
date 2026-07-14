import Foundation

struct AlbumCoverCardPresentation: Identifiable, Equatable, Sendable {
    let id: AlbumScanRecord.ID
    let folderURL: URL
    let displayArtistName: String
    let displayAlbumName: String
    let formatTags: [String]
    let coverURL: URL?
    let contentRevision: UInt64
    let coverSourceName: String?
    let needsAttention: Bool
    let issueHelp: String?
    let canSplitWithXLD: Bool
    let hasEnhancedName: Bool
    let enhancementErrorMessage: String?
}

struct AlbumCoverWallSnapshot: Equatable, Sendable {
    private final class Storage: @unchecked Sendable {
        let cards: [AlbumCoverCardPresentation]

        nonisolated init(cards: [AlbumCoverCardPresentation]) {
            self.cards = cards
        }
    }

    let revision: UInt64
    let filter: AlbumScanResultFilter
    let normalizedQuery: String
    private let storage: Storage

    nonisolated init(
        revision: UInt64,
        filter: AlbumScanResultFilter,
        normalizedQuery: String,
        cards: [AlbumCoverCardPresentation]
    ) {
        self.revision = revision
        self.filter = filter
        self.normalizedQuery = normalizedQuery
        storage = Storage(cards: cards)
    }

    var cards: [AlbumCoverCardPresentation] {
        storage.cards
    }

    var storageIdentity: ObjectIdentifier {
        ObjectIdentifier(storage)
    }

    static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.storageIdentity == rhs.storageIdentity
            && lhs.revision == rhs.revision
            && lhs.filter == rhs.filter
            && lhs.normalizedQuery == rhs.normalizedQuery
    }
}

struct AlbumCoverWallRenderKey: Equatable, Sendable {
    let snapshotRevision: UInt64
    let filter: AlbumScanResultFilter
    let normalizedQuery: String
    let selectedAlbumIDs: Set<AlbumScanRecord.ID>
    let coverWriteMessages: [AlbumScanRecord.ID: String]
    let splittingAlbumIDs: Set<AlbumScanRecord.ID>
    let isSelectionMode: Bool

    init(
        snapshotRevision: UInt64,
        filter: AlbumScanResultFilter,
        normalizedQuery: String,
        selectedAlbumIDs: Set<AlbumScanRecord.ID>,
        coverWriteMessages: [AlbumScanRecord.ID: String],
        splittingAlbumIDs: Set<AlbumScanRecord.ID>,
        isSelectionMode: Bool = false
    ) {
        self.snapshotRevision = snapshotRevision
        self.filter = filter
        self.normalizedQuery = normalizedQuery
        self.selectedAlbumIDs = selectedAlbumIDs
        self.coverWriteMessages = coverWriteMessages
        self.splittingAlbumIDs = splittingAlbumIDs
        self.isSelectionMode = isSelectionMode
    }
}
