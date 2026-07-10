import Foundation

enum AlbumDisplayNameCleaning {
    nonisolated static func displayNames(
        for album: AlbumScanRecord,
        artistName: String,
        albumName: String
    ) -> (artistName: String, albumName: String) {
        guard album.displayedCover != nil else {
            return (artistName, albumName)
        }

        return (
            artistName: clean(artistName),
            albumName: clean(albumName)
        )
    }

    nonisolated static func clean(_ value: String) -> String {
        var cleaned = convertTraditionalChineseToSimplified(value)
        cleaned = removeNoiseBrackets(from: cleaned)
        cleaned = removeStandaloneYears(from: cleaned)
        cleaned = removePlainNoiseTokens(from: cleaned)
        cleaned = normalizeSeparators(in: cleaned)
        return cleaned.isEmpty ? value.trimmingCharacters(in: .whitespacesAndNewlines) : cleaned
    }

    private nonisolated static func convertTraditionalChineseToSimplified(_ value: String) -> String {
        value.applyingTransform(StringTransform(rawValue: "Traditional-Simplified"), reverse: false) ?? value
    }

    private nonisolated static func removeNoiseBrackets(from value: String) -> String {
        let pattern = #"\[[^\]]+\]|【[^】]+】|「[^」]+」|\([^)]*\)|（[^）]*）"#
        return value.replacingOccurrences(
            of: pattern,
            with: { match in
                let content = match
                    .trimmingCharacters(in: CharacterSet(charactersIn: "[]【】「」()（）"))
                return isNoiseToken(content) ? " " : match
            },
            options: .regularExpression
        )
    }

    private nonisolated static func removeStandaloneYears(from value: String) -> String {
        value.replacingOccurrences(
            of: #"(?<!\d)(19|20)\d{2}(?!\d)"#,
            with: " ",
            options: .regularExpression
        )
    }

    private nonisolated static func removePlainNoiseTokens(from value: String) -> String {
        let parts = value.split {
            String($0).rangeOfCharacter(from: separatorCharacters) != nil
        }
        guard parts.count > 1 else { return value }
        return parts
            .map(String.init)
            .filter { !isNoiseToken($0) }
            .joined(separator: " ")
    }

    private nonisolated static func normalizeSeparators(in value: String) -> String {
        value
            .replacingOccurrences(of: #"[\s_\-–—·•|／/\\]+"#, with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private nonisolated static let separatorCharacters = CharacterSet(
        charactersIn: " \t\r\n_-–—·•|／/\\"
    )

    private nonisolated static func isNoiseToken(_ value: String) -> Bool {
        let normalized = value
            .folding(options: [.caseInsensitive, .diacriticInsensitive, .widthInsensitive], locale: nil)
            .replacingOccurrences(of: #"[\s_\-–—·•|／/\\.]+"#, with: "", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()

        guard !normalized.isEmpty else { return true }
        if normalized.range(of: #"^\d{2,3}(bit|khz)$"#, options: .regularExpression) != nil {
            return true
        }
        return noiseTokens.contains(normalized)
    }

    private nonisolated static let noiseTokens: Set<String> = [
        "ape", "wav", "flac", "dsd", "dff", "dsf", "mp3", "m4a", "aac", "alac", "aiff", "aif",
        "sacd", "cd", "dvd", "bluray", "blu ray", "hires", "hi res", "lossless", "vinyl",
        "24bit", "16bit", "96khz", "192khz", "remaster", "remastered", "shmcd", "xrcd",
        "港版", "台版", "台湾版", "日本版", "日版", "美版", "欧版", "韩版", "内地版", "大陆版",
        "限定版", "特别版", "首版", "再版", "完整版", "无损", "整轨", "分轨"
    ]
}

private extension String {
    nonisolated func replacingOccurrences(
        of pattern: String,
        with replacement: (String) -> String,
        options: NSString.CompareOptions
    ) -> String {
        guard options.contains(.regularExpression),
              let regex = try? NSRegularExpression(pattern: pattern) else {
            return self
        }

        let range = NSRange(startIndex..<endIndex, in: self)
        var result = self
        for match in regex.matches(in: self, range: range).reversed() {
            guard let matchRange = Range(match.range, in: self),
                  let resultRange = Range(match.range, in: result) else {
                continue
            }
            result.replaceSubrange(resultRange, with: replacement(String(self[matchRange])))
        }
        return result
    }
}
