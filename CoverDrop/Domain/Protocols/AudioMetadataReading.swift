import Foundation

protocol AudioMetadataReading: Sendable {
    nonisolated func readMetadata(
        at url: URL,
        includingEmbeddedArtwork: Bool
    ) async throws -> AudioMetadata
}

extension AudioMetadataReading {
    nonisolated func readMetadata(at url: URL) async throws -> AudioMetadata {
        try await readMetadata(at: url, includingEmbeddedArtwork: true)
    }
}
