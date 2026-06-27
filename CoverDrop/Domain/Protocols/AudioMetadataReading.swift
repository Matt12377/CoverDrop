import Foundation

protocol AudioMetadataReading: Sendable {
    func readMetadata(at url: URL) async throws -> AudioMetadata
}
