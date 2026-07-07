import Foundation

protocol AlbumNameSuggesting: Sendable {
    func suggestAlbumName(for input: AlbumNameEnhancementInput) async throws -> AlbumNameSuggestion
}

protocol AlbumNameSuggestingResourceReleasing: AlbumNameSuggesting {
    func releaseResources() async
}

struct DisabledAlbumNameSuggesting: AlbumNameSuggesting {
    func suggestAlbumName(for input: AlbumNameEnhancementInput) async throws -> AlbumNameSuggestion {
        AlbumNameSuggestion(
            artistName: input.originalArtistName,
            albumName: input.originalAlbumName
        )
    }
}
