import CryptoKit
import Foundation

private struct LegacySnapshot: Decodable {
    let scanResult: ScanResult

    struct ScanResult: Decodable {
        let albums: [Album]
        let looseAudioPaths: [String]
    }

    struct Album: Decodable {
        let folderPath: String
        let artistName: String
        let albumName: String
        let audioFiles: [AudioFile]
        let displayedCover: Presence?
    }

    struct AudioFile: Decodable {
        let path: String
        let relativePath: String
        let format: String
        let metadata: Metadata?
        let readError: String?
    }

    struct Metadata: Decodable {
        let title: String?
        let artist: String?
        let albumArtist: String?
        let album: String?
        let discNumber: Int?
        let trackNumber: Int?
        let durationSeconds: Int?
        let embeddedArtworkPath: String?
    }

    struct Presence: Decodable {
        init(from decoder: any Decoder) throws {}
    }
}

@main
private enum AlbumNameCleaningAudit {
    private static let majorityThreshold = 0.70

    static func main() throws {
        guard CommandLine.arguments.count == 2 else {
            FileHandle.standardError.write(
                Data("用法：AlbumNameCleaningAudit <扫描快照.db>\n".utf8)
            )
            Foundation.exit(64)
        }

        let snapshotURL = URL(fileURLWithPath: CommandLine.arguments[1])
        let data = try Data(contentsOf: snapshotURL, options: [.mappedIfSafe])
        let snapshot = try JSONDecoder().decode(LegacySnapshot.self, from: data)
        let report = audit(snapshot)
        let output = try JSONSerialization.data(
            withJSONObject: report,
            options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        )
        FileHandle.standardOutput.write(output)
        FileHandle.standardOutput.write(Data("\n".utf8))
    }

    private static func audit(_ snapshot: LegacySnapshot) -> [String: Any] {
        var trackCount = 0
        var metadataCount = 0
        var readErrorCount = 0
        var titleCount = 0
        var artistTagCount = 0
        var albumArtistTagCount = 0
        var albumTagCount = 0
        var absolutePathCount = 0
        var relativePathConsistentCount = 0
        var formatExtensionConsistentCount = 0
        var leadingTrackNumberCount = 0
        var genericTrackNameCount = 0
        var nestedRelativePathCount = 0
        var discSubfolderCount = 0
        var metadataTitleContainedCount = 0
        var metadataArtistPrefixCount = 0
        var missingTitleUsableFilenameCount = 0
        var missingTitlePlaceholderFilenameCount = 0
        var doubleTrackNumberCount = 0
        var formats: [String: Int] = [:]
        var hasher = SHA256()

        var coveredAlbumCount = 0
        var rawAlbumChangedCount = 0
        var rawArtistChangedCount = 0
        var potentialDisplayAlbumChangedCount = 0
        var potentialDisplayArtistChangedCount = 0
        var runtimeDisplayAlbumChangedCount = 0
        var emptyOutputCount = 0
        var idempotenceFailureCount = 0
        var noisyAlbumCount = 0
        var residualNoisyAlbumCount = 0
        var beforeNoiseCategories: [String: Int] = [:]
        var residualNoiseCategories: [String: Int] = [:]
        var residualNames: [(name: String, cleaned: String, categories: [String])] = []
        var albumTagEligibleCount = 0
        var albumTagMatchedCount = 0
        var artistTagEligibleCount = 0
        var artistTagMatchedCount = 0

        for legacyAlbum in snapshot.scanResult.albums {
            if legacyAlbum.displayedCover != nil {
                coveredAlbumCount += 1
            }

            let record = makeAlbumRecord(legacyAlbum, forceCover: true)
            let potentialNames = AlbumDisplayNameCleaning.displayNames(
                for: record,
                artistName: record.artistName,
                albumName: record.albumName
            )
            let runtimeRecord = makeAlbumRecord(legacyAlbum, forceCover: false)
            let runtimeNames = AlbumDisplayNameCleaning.displayNames(
                for: runtimeRecord,
                artistName: runtimeRecord.artistName,
                albumName: runtimeRecord.albumName
            )
            let rawCleanedAlbum = AlbumNameCleaning.cleanAlbumName(
                legacyAlbum.albumName,
                artistName: legacyAlbum.artistName
            )
            let rawCleanedArtist = AlbumNameCleaning.cleanArtistName(legacyAlbum.artistName)

            if rawCleanedAlbum != legacyAlbum.albumName { rawAlbumChangedCount += 1 }
            if rawCleanedArtist != legacyAlbum.artistName { rawArtistChangedCount += 1 }
            if potentialNames.albumName != legacyAlbum.albumName {
                potentialDisplayAlbumChangedCount += 1
            }
            if potentialNames.artistName != legacyAlbum.artistName {
                potentialDisplayArtistChangedCount += 1
            }
            if runtimeNames.albumName != legacyAlbum.albumName {
                runtimeDisplayAlbumChangedCount += 1
            }
            if potentialNames.albumName.isEmpty || potentialNames.artistName.isEmpty {
                emptyOutputCount += 1
            }

            let cleanedAgain = AlbumNameCleaning.cleanAlbumName(
                potentialNames.albumName,
                artistName: potentialNames.artistName
            )
            if cleanedAgain != potentialNames.albumName ||
                AlbumNameCleaning.cleanArtistName(potentialNames.artistName) != potentialNames.artistName {
                idempotenceFailureCount += 1
            }

            let beforeCategories = structuralNoiseCategories(
                in: legacyAlbum.albumName,
                artistName: legacyAlbum.artistName
            )
            let afterCategories = structuralNoiseCategories(
                in: potentialNames.albumName,
                artistName: potentialNames.artistName
            )
            if !beforeCategories.isEmpty {
                noisyAlbumCount += 1
                increment(categories: beforeCategories, in: &beforeNoiseCategories)
                if !afterCategories.isEmpty {
                    residualNoisyAlbumCount += 1
                    increment(categories: afterCategories, in: &residualNoiseCategories)
                    residualNames.append(
                        (legacyAlbum.albumName, potentialNames.albumName, afterCategories.sorted())
                    )
                }
            }

            let metadataAlbumValues = legacyAlbum.audioFiles.compactMap { $0.metadata?.album }
            if let candidate = stableCandidate(
                metadataAlbumValues,
                clean: {
                    AlbumNameCleaning.cleanAlbumName($0, artistName: potentialNames.artistName)
                },
                rejectsPlaceholder: true
            ), corroborates(candidate, rawValue: legacyAlbum.albumName) {
                albumTagEligibleCount += 1
                if AlbumNameCleaning.canonicalKey(candidate) ==
                    AlbumNameCleaning.canonicalKey(potentialNames.albumName) {
                    albumTagMatchedCount += 1
                }
            }

            let albumArtistValues = legacyAlbum.audioFiles.compactMap { $0.metadata?.albumArtist }
            let artistValues = legacyAlbum.audioFiles.compactMap { $0.metadata?.artist }
            let artistCandidate = stableCandidate(
                albumArtistValues,
                clean: AlbumNameCleaning.cleanArtistName,
                rejectsPlaceholder: false
            ) ?? stableCandidate(
                artistValues,
                clean: AlbumNameCleaning.cleanArtistName,
                rejectsPlaceholder: false
            )
            if let artistCandidate,
               corroborates(artistCandidate, rawValue: legacyAlbum.artistName) {
                artistTagEligibleCount += 1
                if AlbumNameCleaning.canonicalKey(artistCandidate) ==
                    AlbumNameCleaning.canonicalKey(potentialNames.artistName) {
                    artistTagMatchedCount += 1
                }
            }

            for audioFile in legacyAlbum.audioFiles {
                trackCount += 1
                formats[audioFile.format, default: 0] += 1
                hasher.update(data: Data(audioFile.relativePath.utf8))
                hasher.update(data: Data([0]))

                let fileURL = URL(fileURLWithPath: audioFile.path)
                let stem = fileURL.deletingPathExtension().lastPathComponent
                let metadata = audioFile.metadata
                if metadata != nil { metadataCount += 1 }
                if audioFile.readError != nil { readErrorCount += 1 }
                if nonempty(metadata?.title) != nil { titleCount += 1 }
                if nonempty(metadata?.artist) != nil { artistTagCount += 1 }
                if nonempty(metadata?.albumArtist) != nil { albumArtistTagCount += 1 }
                if nonempty(metadata?.album) != nil { albumTagCount += 1 }
                if fileURL.path.hasPrefix("/") { absolutePathCount += 1 }

                let expectedRelativePath = fileURL.path.replacingPrefix(
                    URL(fileURLWithPath: legacyAlbum.folderPath, isDirectory: true).path + "/",
                    with: ""
                )
                if expectedRelativePath == audioFile.relativePath {
                    relativePathConsistentCount += 1
                }
                if fileURL.pathExtension.caseInsensitiveCompare(audioFile.format) == .orderedSame {
                    formatExtensionConsistentCount += 1
                }
                if matches(stem, #"^\s*(?:\d{1,4}\s*[-_.、． ]+|(?:track|音轨|音軌)\s*0*\d+)"#) {
                    leadingTrackNumberCount += 1
                }
                let fallbackStem = removingTrackPrefix(from: stem)
                if isPlaceholderTrackName(fallbackStem) { genericTrackNameCount += 1 }
                if audioFile.relativePath.contains("/") { nestedRelativePathCount += 1 }
                if matches(
                    audioFile.relativePath,
                    #"(?i)(?:^|/)(?:cd|disc|disk)\s*0*\d+(?:/|$)"#
                ) {
                    discSubfolderCount += 1
                }
                if let title = nonempty(metadata?.title),
                   canonical(stem).contains(canonical(title)) {
                    metadataTitleContainedCount += 1
                }
                if let artist = nonempty(metadata?.artist),
                   canonical(removingTrackPrefix(from: stem)).hasPrefix(canonical(artist)) {
                    metadataArtistPrefixCount += 1
                }
                if nonempty(metadata?.title) == nil {
                    if isPlaceholderTrackName(fallbackStem) {
                        missingTitlePlaceholderFilenameCount += 1
                    } else {
                        missingTitleUsableFilenameCount += 1
                    }
                }
                if matches(
                    stem,
                    #"^\s*(\d{1,4})\s*[-_.、． ]+\s*\1\s*[-_.、． ]+"#
                ) {
                    doubleTrackNumberCount += 1
                }
            }
        }

        let digest = hasher.finalize().map { String(format: "%02x", $0) }.joined()
        let residualRate = noisyAlbumCount == 0
            ? 0
            : Double(residualNoisyAlbumCount) / Double(noisyAlbumCount)
        let albumTagMatchRate = matchRate(
            matched: albumTagMatchedCount,
            eligible: albumTagEligibleCount
        )
        let artistTagMatchRate = matchRate(
            matched: artistTagMatchedCount,
            eligible: artistTagEligibleCount
        )
        let allFilenamesConsistent = absolutePathCount == trackCount &&
            relativePathConsistentCount == trackCount &&
            formatExtensionConsistentCount == trackCount
        let coveragePassed = residualRate <= 0.02 &&
            albumTagMatchRate >= 0.98 &&
            artistTagMatchRate >= 0.98 &&
            emptyOutputCount == 0 &&
            idempotenceFailureCount == 0 &&
            allFilenamesConsistent

        return [
            "qualityGate": [
                "passed": coveragePassed,
                "maximumResidualNoiseRate": 0.02,
                "minimumTagMatchRate": 0.98,
                "albumTagMatchRate": albumTagMatchRate,
                "artistTagMatchRate": artistTagMatchRate,
                "allFilenamesConsistent": allFilenamesConsistent
            ],
            "snapshot": [
                "albumCount": snapshot.scanResult.albums.count,
                "trackCount": trackCount,
                "looseAudioCount": snapshot.scanResult.looseAudioPaths.count,
                "coveredAlbumCount": coveredAlbumCount,
                "missingCoverAlbumCount": snapshot.scanResult.albums.count - coveredAlbumCount,
                "orderedRelativePathSHA256": digest
            ],
            "metadata": [
                "metadataObjectCount": metadataCount,
                "readErrorCount": readErrorCount,
                "titleCount": titleCount,
                "artistCount": artistTagCount,
                "albumArtistCount": albumArtistTagCount,
                "albumCount": albumTagCount
            ],
            "filenameSummary": [
                "formats": formats,
                "absolutePathCount": absolutePathCount,
                "relativePathConsistentCount": relativePathConsistentCount,
                "formatExtensionConsistentCount": formatExtensionConsistentCount,
                "leadingTrackNumberCount": leadingTrackNumberCount,
                "genericTrackNameCount": genericTrackNameCount,
                "nestedRelativePathCount": nestedRelativePathCount,
                "discSubfolderCount": discSubfolderCount,
                "metadataTitleContainedCount": metadataTitleContainedCount,
                "metadataArtistPrefixCount": metadataArtistPrefixCount,
                "missingTitleUsableFilenameCount": missingTitleUsableFilenameCount,
                "missingTitlePlaceholderFilenameCount": missingTitlePlaceholderFilenameCount,
                "doubleTrackNumberCount": doubleTrackNumberCount
            ],
            "cleaning": [
                "rawAlbumChangedCount": rawAlbumChangedCount,
                "rawArtistChangedCount": rawArtistChangedCount,
                "potentialDisplayAlbumChangedCount": potentialDisplayAlbumChangedCount,
                "potentialDisplayArtistChangedCount": potentialDisplayArtistChangedCount,
                "runtimeDisplayAlbumChangedCount": runtimeDisplayAlbumChangedCount,
                "noisyAlbumCount": noisyAlbumCount,
                "residualNoisyAlbumCount": residualNoisyAlbumCount,
                "residualNoiseRate": residualRate,
                "beforeNoiseCategories": beforeNoiseCategories,
                "residualNoiseCategories": residualNoiseCategories,
                "albumTagEligibleCount": albumTagEligibleCount,
                "albumTagMatchedCount": albumTagMatchedCount,
                "artistTagEligibleCount": artistTagEligibleCount,
                "artistTagMatchedCount": artistTagMatchedCount,
                "emptyOutputCount": emptyOutputCount,
                "idempotenceFailureCount": idempotenceFailureCount,
                "topResiduals": residualNames.prefix(80).map {
                    ["original": $0.name, "cleaned": $0.cleaned, "categories": $0.categories]
                }
            ]
        ]
    }

    private static func matchRate(matched: Int, eligible: Int) -> Double {
        eligible == 0 ? 1 : Double(matched) / Double(eligible)
    }

    private static func makeAlbumRecord(
        _ album: LegacySnapshot.Album,
        forceCover: Bool
    ) -> AlbumScanRecord {
        let folderURL = URL(fileURLWithPath: album.folderPath, isDirectory: true)
        let cover: CoverCandidate? = (forceCover || album.displayedCover != nil)
            ? CoverCandidate(
                url: folderURL.appendingPathComponent("cover.jpg"),
                relativePath: "cover.jpg",
                namePriority: 0,
                depth: 0
            )
            : nil
        return AlbumScanRecord(
            folderURL: folderURL,
            artistName: album.artistName,
            albumName: album.albumName,
            audioFiles: album.audioFiles.map { audioFile in
                AudioFileRecord(
                    url: URL(fileURLWithPath: audioFile.path),
                    relativePath: audioFile.relativePath,
                    format: audioFile.format,
                    metadata: audioFile.metadata.map { metadata in
                        AudioMetadata(
                            title: metadata.title,
                            artist: metadata.artist,
                            albumArtist: metadata.albumArtist,
                            album: metadata.album,
                            discNumber: metadata.discNumber,
                            trackNumber: metadata.trackNumber,
                            durationSeconds: metadata.durationSeconds,
                            embeddedArtworkURL: metadata.embeddedArtworkPath.map(URL.init(fileURLWithPath:))
                        )
                    },
                    readError: audioFile.readError
                )
            },
            displayedCover: cover,
            issues: []
        )
    }

    private static func stableCandidate(
        _ values: [String],
        clean: (String) -> String,
        rejectsPlaceholder: Bool
    ) -> String? {
        let cleaned = values.compactMap { value -> (key: String, value: String)? in
            guard let value = nonempty(value) else { return nil }
            let result = clean(value)
            let key = AlbumNameCleaning.canonicalKey(result)
            guard !key.isEmpty else { return nil }
            return (key, result)
        }
        guard !cleaned.isEmpty else { return nil }
        let groups = Dictionary(grouping: cleaned, by: \.key).sorted {
            $0.value.count > $1.value.count
        }
        guard let winner = groups.first else { return nil }
        if groups.count > 1, groups[1].value.count == winner.value.count { return nil }
        guard Double(winner.value.count) / Double(cleaned.count) >= majorityThreshold else {
            return nil
        }
        guard let candidate = winner.value.first?.value else { return nil }
        if rejectsPlaceholder, AlbumNameCleaning.isPlaceholderAlbumName(candidate) {
            return nil
        }
        return candidate
    }

    private static func corroborates(_ candidate: String, rawValue: String) -> Bool {
        let candidateKey = AlbumNameCleaning.canonicalKey(candidate)
        let rawKey = AlbumNameCleaning.canonicalKey(rawValue)
        return !candidateKey.isEmpty && rawKey.contains(candidateKey)
    }

    private static func structuralNoiseCategories(
        in value: String,
        artistName: String
    ) -> Set<String> {
        var categories: Set<String> = []
        if matches(value, #"^\s*[\[【](?:qobuz|hi[ -]?res|sony|tidal|mora|amz|amazon|mqs?|cm|m)[\]】]"#) {
            categories.insert("leadingSource")
        }
        if matches(
            value,
            #"^\s*(?:[\[【(（]?(?:19|20)\d{2}[\]】)）]?\s*[-_.—–]|(?:19|20)\d{2}[._-](?:0?[1-9]|1[0-2]))"#
        ) {
            categories.insert("leadingDate")
        }
        if matches(value, #"^\s*\d{1,3}\s*[、．]"#) {
            categories.insert("leadingCatalogIndex")
        }
        let simplifiedArtist = AlbumNameCleaning.cleanArtistName(artistName)
        let escapedArtist = NSRegularExpression.escapedPattern(for: simplifiedArtist)
        let simplifiedValue = value.applyingTransform(
            StringTransform(rawValue: "Traditional-Simplified"),
            reverse: false
        ) ?? value
        if matches(
            simplifiedValue,
            #"^(?:\s*[\[【][^\]】]+[\]】]\s*)?(?:(?:19|20)\d{2}(?:[._-]\d{1,2})?\s*[-_.—–]?\s*)?"#
                + escapedArtist
                + #"(?:\s+|\s*[-_.—–《〈（(【\[])"#
        ) {
            categories.insert("duplicateArtist")
        }
        if matches(
            value,
            #"(?i)(?:[\[【(（]\s*(?:wav|flac|ape|dsd|dff|dsf|sacd(?:iso)?|cue|hi[ -]?res|\d{2}\s*[- ]\s*\d{2,3}|qobuz|tidal)[^\]】)）]*[\]】)）]|(?:\s|[-–—])(?:wav|flac|ape|dsd|dff|dsf|sacd(?:iso)?|cue|\d\s*bit\s*\d(?:\.\d+)?mhz)\s*$)"#
        ) {
            categories.insert("formatOrSource")
        }
        if matches(
            value,
            #"(?i)(?:\s|[-–—])(?:16|20|24|32)\s*(?:bit|b)?\s*[-_/ ]\s*(?:44(?:\.1)?|48|88(?:\.2)?|96|176(?:\.4)?|192)(?:\s*k?hz)?\s*$"#
        ) {
            categories.insert("resolution")
        }
        if matches(value, #"\s+(?:19|20)\d{2}\s*$"#) {
            categories.insert("trailingYear")
        }
        if matches(value, #"(?i)\s+(?:\d+\s*)?(?:cd|disc|disk)\s*(?:\d+|[a-z])?\s*$"#) {
            categories.insert("discSuffix")
        }
        return categories
    }

    private static func increment(
        categories: Set<String>,
        in counts: inout [String: Int]
    ) {
        for category in categories {
            counts[category, default: 0] += 1
        }
    }

    private static func nonempty(_ value: String?) -> String? {
        guard let value else { return nil }
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    private static func canonical(_ value: String) -> String {
        AlbumNameCleaning.canonicalKey(value)
    }

    private static func removingTrackPrefix(from value: String) -> String {
        value.replacingOccurrences(
            of: #"^\s*(?:\d{1,4}\s*[-_.、． ]+|(?:track|音轨|音軌)\s*0*\d+\s*[-_.、． ]*)"#,
            with: "",
            options: [.regularExpression, .caseInsensitive]
        )
    }

    private static func isPlaceholderTrackName(_ value: String) -> Bool {
        matches(
            value,
            #"(?i)^\s*(?:(?:track|音轨|音軌)\s*0*\d+|unknown(?:\s+artist)?(?:\s*[-_.]\s*\d+)?|未知艺术家(?:\s*[-_.]\s*\d+)?)\s*$"#
        )
    }

    private static func matches(_ value: String, _ pattern: String) -> Bool {
        value.range(of: pattern, options: [.regularExpression, .caseInsensitive]) != nil
    }
}

private extension String {
    func replacingPrefix(_ prefix: String, with replacement: String) -> String {
        guard hasPrefix(prefix) else { return self }
        return replacement + dropFirst(prefix.count)
    }
}
