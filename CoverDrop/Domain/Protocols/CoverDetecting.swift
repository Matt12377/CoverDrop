import Foundation

struct CoverDetectionResult: Equatable, Sendable {
    let selected: CoverCandidate?
    let invalidNamedPaths: [String]
}

protocol CoverDetecting: Sendable {
    nonisolated func detectCover(in albumURL: URL) async throws -> CoverDetectionResult
}
