import Foundation

struct AlbumCoverWorkflowPresentationState: Equatable, Sendable {
    enum Destination: Equatable, Sendable {
        case albumDetail
        case coverSearch
    }

    private(set) var destination: Destination = .albumDetail

    var usesAlbumDetailDropZone: Bool {
        destination == .albumDetail
    }

    var containerSize: CGSize {
        switch destination {
        case .albumDetail:
            CGSize(width: 680, height: 520)
        case .coverSearch:
            CGSize(width: 1_100, height: 700)
        }
    }

    mutating func showCoverSearch() {
        destination = .coverSearch
    }

    mutating func showAlbumDetail() {
        destination = .albumDetail
    }

    mutating func handleAlbumRemoval() {
        destination = .albumDetail
    }
}
