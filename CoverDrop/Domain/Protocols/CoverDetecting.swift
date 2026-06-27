import Foundation

struct CoverDetectionResult: Equatable, Sendable {
    let selected: CoverCandidate?
    let invalidNamedPaths: [String]
}

protocol CoverDetecting: Sendable {
    func detectCover(in albumURL: URL) async throws -> CoverDetectionResult
}
