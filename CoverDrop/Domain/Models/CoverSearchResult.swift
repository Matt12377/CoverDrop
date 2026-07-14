import Foundation

struct CoverSearchParameters: Equatable, Sendable {
    let countryCode: String
    let limit: Int
    let media: String
    let entity: String

    init(
        countryCode: String = "CN",
        limit: Int = 50,
        media: String = "music",
        entity: String = "album"
    ) {
        self.countryCode = countryCode
        self.limit = min(max(limit, 1), 200)
        self.media = media
        self.entity = entity
    }
}

struct CoverSearchResult: Identifiable, Equatable, Sendable {
    let id: String
    let sourceName: String
    let albumName: String
    let artistName: String
    let thumbnailURL: URL
    let imageURL: URL
    let externalURL: URL?

    nonisolated init(
        id: String,
        sourceName: String,
        albumName: String,
        artistName: String,
        thumbnailURL: URL,
        imageURL: URL,
        externalURL: URL?
    ) {
        self.id = id
        self.sourceName = sourceName
        self.albumName = albumName
        self.artistName = artistName
        self.thumbnailURL = thumbnailURL
        self.imageURL = imageURL
        self.externalURL = externalURL
    }
}
