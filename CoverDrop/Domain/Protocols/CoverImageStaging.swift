import Foundation

protocol CoverImageStaging: Sendable {
    func stageImageData(
        _ data: Data,
        suggestedExtension: String?
    ) async throws -> URL

    func stageRemoteImage(at remoteURL: URL) async throws -> URL

    func prefetchRemoteImage(at remoteURL: URL) async
}
