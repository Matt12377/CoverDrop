import Foundation

struct AlbumAudioTrackDisplayItem: Equatable, Sendable {
    let sequenceText: String
    let title: String
    let formatText: String
    let durationText: String?
    let relativePath: String
    let hasReadError: Bool
    let readError: String?

    init(audioFile: AudioFileRecord) {
        self.sequenceText = Self.sequenceText(
            discNumber: audioFile.metadata?.discNumber,
            trackNumber: audioFile.metadata?.trackNumber
        )
        self.title = Self.title(metadataTitle: audioFile.metadata?.title, relativePath: audioFile.relativePath)
        self.formatText = audioFile.format.uppercased()
        self.durationText = audioFile.metadata?.durationSeconds.map(Self.durationText(seconds:))
        self.relativePath = audioFile.relativePath
        self.hasReadError = audioFile.readError != nil
        self.readError = audioFile.readError
    }

    private static func sequenceText(discNumber: Int?, trackNumber: Int?) -> String {
        switch (discNumber, trackNumber) {
        case let (.some(disc), .some(track)):
            return "\(disc)-\(paddedTrackNumber(track))"
        case let (nil, .some(track)):
            return paddedTrackNumber(track)
        case let (.some(disc), nil):
            return "碟 \(disc)"
        case (nil, nil):
            return "-"
        }
    }

    private static func title(metadataTitle: String?, relativePath: String) -> String {
        if let metadataTitle,
           !metadataTitle.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return metadataTitle
        }

        let fileName = URL(fileURLWithPath: relativePath).lastPathComponent
        return fileName.isEmpty ? relativePath : fileName
    }

    private static func durationText(seconds: Int) -> String {
        let normalizedSeconds = max(0, seconds)
        let hours = normalizedSeconds / 3600
        let minutes = (normalizedSeconds % 3600) / 60
        let seconds = normalizedSeconds % 60

        if hours > 0 {
            return "\(hours):\(twoDigits(minutes)):\(twoDigits(seconds))"
        }

        return "\(minutes):\(twoDigits(seconds))"
    }

    private static func paddedTrackNumber(_ trackNumber: Int) -> String {
        if trackNumber >= 0, trackNumber < 10 {
            return "0\(trackNumber)"
        }

        return "\(trackNumber)"
    }

    private static func twoDigits(_ value: Int) -> String {
        value < 10 ? "0\(value)" : "\(value)"
    }
}
