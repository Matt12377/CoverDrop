import Foundation

enum AlbumNameCleaning {
    nonisolated static func cleanArtistName(_ value: String) -> String {
        let fallback = normalizedText(value)
        var current = fallback

        for _ in 0..<4 {
            let previous = current
            current = removingTrailingNoiseBracketGroups(from: current)
            current = current.replacingOccurrences(
                of: #"\s*(?:专辑|專輯|合集|合辑|合輯)\s*$"#,
                with: "",
                options: .regularExpression
            )
            current = trimmedEdgeSeparators(in: normalizedWhitespace(current))
            if current == previous { break }
        }

        return meaningful(current) ? current : fallback
    }

    nonisolated static func cleanAlbumName(
        _ value: String,
        artistName: String?
    ) -> String {
        let fallback = normalizedText(value)
        let normalizedArtistName = artistName.map(cleanArtistName)
        var current = fallback

        for _ in 0..<8 {
            let previous = current
            current = removingLeadingNoiseBracketGroups(from: current)
            current = trimmedEdgeSeparators(in: current)
            current = removingLeadingCatalogIndex(from: current)
            current = removingLeadingDate(from: current, artistName: normalizedArtistName)
            current = removingLeadingArtist(from: current, artistName: normalizedArtistName)
            current = extractingSingleBookTitle(
                from: current,
                artistName: normalizedArtistName
            ) ?? current
            current = removingTrailingNoiseBracketGroups(from: current)
            current = removingTrailingPlainNoise(from: current)
            current = removingWarezAlbumSuffix(from: current)
            current = unwrappingWholeBracketGroup(in: current)
            current = normalizedWhitespace(trimmedEdgeSeparators(in: current))
            if current == previous { break }
        }

        return meaningful(current) ? current : fallback
    }

    nonisolated static func canonicalKey(_ value: String) -> String {
        let folded = normalizedText(value)
            .folding(
                options: [.caseInsensitive, .diacriticInsensitive, .widthInsensitive],
                locale: nil
            )
            .lowercased()

        return String(
            folded.unicodeScalars.filter { CharacterSet.alphanumerics.contains($0) }
        )
    }

    nonisolated static func isPlaceholderAlbumName(_ value: String) -> Bool {
        placeholderAlbumNames.contains(canonicalKey(value))
    }

    private nonisolated static func normalizedText(_ value: String) -> String {
        let widthFolded = value.folding(options: [.widthInsensitive], locale: nil)
        let simplified = widthFolded.applyingTransform(
            StringTransform(rawValue: "Traditional-Simplified"),
            reverse: false
        ) ?? widthFolded
        return normalizedWhitespace(simplified)
    }

    private nonisolated static func normalizedWhitespace(_ value: String) -> String {
        value
            .components(separatedBy: .whitespacesAndNewlines)
            .filter { !$0.isEmpty }
            .joined(separator: " ")
    }

    private nonisolated static func meaningful(_ value: String) -> Bool {
        !value.isEmpty && value.rangeOfCharacter(from: .alphanumerics) != nil
    }

    private nonisolated static func trimmedEdgeSeparators(in value: String) -> String {
        value.trimmingCharacters(in: edgeSeparators)
    }

    private nonisolated static func removingLeadingCatalogIndex(from value: String) -> String {
        firstCapturedGroup(
            in: value,
            pattern: #"^\s*\d{1,3}\s*[、．]\s*(\S.*)$"#
        ) ?? value
    }

    private nonisolated static func removingLeadingDate(
        from value: String,
        artistName: String?
    ) -> String {
        let patterns = [
            #"^\s*(?:19|20)\d{6}\s*[-_.—–]*\s*(\S.*)$"#,
            #"^\s*[\[【(（]\s*(?:19|20)\d{2}\s*[-_.—–]+\s*(\S.*)$"#,
            #"^\s*(?:19|20)\d{2}[._-](?:0?[1-9]|1[0-2])(?:[._-](?:0?[1-9]|[12]\d|3[01]))?(?!\d)\s*[-_.—–]*\s*(\S.*)$"#,
            #"^\s*(?:19|20)\d{2}\s*(?:年\s*)?[-_.—–]+\s*(\S.*)$"#,
            #"^\s*(?:19|20)\d{2}\s+(?=[\[【《〈])(\S.*)$"#,
            #"^\s*[（(](?:19|20)\d{2}[）)]\s*[-_.—–]*\s*(\S.*)$"#
        ]

        for pattern in patterns {
            if let captured = firstCapturedGroup(in: value, pattern: pattern) {
                return captured
            }
        }

        if let artistName, !artistName.isEmpty {
            let escapedArtistName = NSRegularExpression.escapedPattern(for: artistName)
            let artistPatterns = [
                #"^\s*(?:19|20)\d{2}\s+("#
                    + escapedArtistName
                    + #"(?:\s|[-_.—–《〈（(【\[]).*)$"#,
                #"^\s*(?:19|20)\d{2}("#
                    + escapedArtistName
                    + #"(?:\s|[-_.—–《〈（(【\[]).*)$"#
            ]
            for pattern in artistPatterns {
                if let captured = firstCapturedGroup(in: value, pattern: pattern) {
                    return captured
                }
            }
        }

        return value
    }

    private nonisolated static func removingLeadingArtist(
        from value: String,
        artistName: String?
    ) -> String {
        guard let artistName, !artistName.isEmpty else { return value }

        let escapedArtistName = NSRegularExpression.escapedPattern(for: artistName)
        let patterns = [
            #"^\s*"# + escapedArtistName + #"\s*((?:19|20)\d{2}[-_.—–].*)$"#,
            #"^\s*"# + escapedArtistName + #"\s*(?:[._—–-]+\s*)+(\S.*)$"#,
            #"^\s*"# + escapedArtistName + #"\s+(\S.*)$"#,
            #"^\s*"# + escapedArtistName + #"\s*(?=[《〈（(【\[])(\S.*)$"#
        ]

        for pattern in patterns {
            if let captured = firstCapturedGroup(in: value, pattern: pattern) {
                return captured
            }
        }
        return value
    }

    private nonisolated static func removingLeadingNoiseBracketGroups(
        from value: String
    ) -> String {
        var current = value
        while let group = leadingBracketGroup(in: current),
              isLeadingNoiseBracketContent(group.content) {
            current.removeSubrange(group.range)
            current = trimmedEdgeSeparators(in: normalizedWhitespace(current))
        }
        return current
    }

    private nonisolated static func removingTrailingNoiseBracketGroups(
        from value: String
    ) -> String {
        var current = value
        while let group = trailingBracketGroup(in: current) {
            let isWholeGroup = group.range == current.startIndex..<current.endIndex
            if isWholeGroup, !isLeadingNoiseBracketContent(group.content) {
                break
            }
            guard isNoiseBracketContent(group.content) else { break }
            current.removeSubrange(group.range)
            current = trimmedEdgeSeparators(in: normalizedWhitespace(current))
        }
        return current
    }

    private nonisolated static func removingTrailingPlainNoise(from value: String) -> String {
        var current = value.replacingOccurrences(
            of: #"(?i)([\]】)）])(?:cd|disc|disk)\s*(?:\d+|[a-z])\s*$"#,
            with: "$1",
            options: .regularExpression
        )
        for pattern in trailingNoisePatterns {
            let updated = current.replacingOccurrences(
                of: pattern,
                with: "",
                options: [.regularExpression, .caseInsensitive]
            )
            if updated != current, meaningful(updated) {
                current = trimmedEdgeSeparators(in: normalizedWhitespace(updated))
            }
        }
        return current
    }

    private nonisolated static func removingWarezAlbumSuffix(from value: String) -> String {
        let withoutSuffix = value.replacingOccurrences(
            of: #"([\]】)）》〉])\s*[._-]*专辑[._-]*$"#,
            with: "$1",
            options: .regularExpression
        )
        guard withoutSuffix != value,
              let group = leadingBracketGroup(in: withoutSuffix),
              group.range == withoutSuffix.startIndex..<withoutSuffix.endIndex,
              meaningful(group.content) else {
            return withoutSuffix
        }
        return normalizedWhitespace(group.content)
    }

    private nonisolated static func extractingSingleBookTitle(
        from value: String,
        artistName: String?
    ) -> String? {
        let pattern = #"《([^》]+)》|〈([^〉]+)〉"#
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return nil }
        let range = NSRange(value.startIndex..<value.endIndex, in: value)
        let matches = regex.matches(in: value, range: range)
        guard matches.count == 1,
              let match = matches.first,
              let matchRange = Range(match.range, in: value) else {
            return nil
        }

        let contentRangeIndex = match.range(at: 1).location != NSNotFound ? 1 : 2
        guard let contentRange = Range(match.range(at: contentRangeIndex), in: value) else {
            return nil
        }

        let prefix = String(value[..<matchRange.lowerBound])
        let suffix = String(value[matchRange.upperBound...])
        guard isTrustedBookTitlePrefix(prefix, artistName: artistName),
              containsOnlyNoise(suffix) else {
            return nil
        }

        let content = normalizedWhitespace(String(value[contentRange]))
        return meaningful(content) ? content : nil
    }

    private nonisolated static func isTrustedBookTitlePrefix(
        _ value: String,
        artistName: String?
    ) -> Bool {
        let trimmed = trimmedEdgeSeparators(in: normalizedWhitespace(value))
        if trimmed.isEmpty { return true }

        if let artistName,
           canonicalKey(trimmed).contains(canonicalKey(artistName)) {
            return true
        }

        return trimmed.range(
            of: #"(?:唱片|文化|音乐|音樂|第[一二三四五六七八九十百\d]+张专辑|第[一二三四五六七八九十百\d]+張專輯|专辑|專輯)"#,
            options: .regularExpression
        ) != nil
    }

    private nonisolated static func containsOnlyNoise(_ value: String) -> Bool {
        var current = normalizedWhitespace(value)
        for _ in 0..<6 {
            let previous = current
            current = removingTrailingNoiseBracketGroups(from: current)
            current = removingTrailingPlainNoise(from: current)
            current = current.replacingOccurrences(
                of: #"\s*(?:专辑|專輯|双碟装|雙碟裝)\s*$"#,
                with: "",
                options: .regularExpression
            )
            current = trimmedEdgeSeparators(in: normalizedWhitespace(current))
            if current == previous { break }
        }
        return current.isEmpty || isNoiseBracketContent(current)
    }

    private nonisolated static func unwrappingWholeBracketGroup(in value: String) -> String {
        guard let group = leadingBracketGroup(in: value),
              group.range == value.startIndex..<value.endIndex,
              !isLeadingNoiseBracketContent(group.content),
              meaningful(group.content) else {
            return value
        }
        return normalizedWhitespace(group.content)
    }

    private nonisolated static func leadingBracketGroup(
        in value: String
    ) -> (content: String, range: Range<String.Index>)? {
        guard let start = value.firstIndex(where: { !$0.isWhitespace }),
              let closing = bracketPairs[value[start]],
              let end = matchingClosingIndex(in: value, from: start, opening: value[start], closing: closing) else {
            return nil
        }

        let contentStart = value.index(after: start)
        let content = String(value[contentStart..<end])
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !content.isEmpty else { return nil }
        return (content, start..<value.index(after: end))
    }

    private nonisolated static func trailingBracketGroup(
        in value: String
    ) -> (content: String, range: Range<String.Index>)? {
        guard let end = value.lastIndex(where: { !$0.isWhitespace }),
              let opening = closingBracketPairs[value[end]],
              let start = matchingOpeningIndex(in: value, from: end, opening: opening, closing: value[end]) else {
            return nil
        }

        let contentStart = value.index(after: start)
        let content = String(value[contentStart..<end])
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !content.isEmpty else { return nil }
        return (content, start..<value.index(after: end))
    }

    private nonisolated static func matchingClosingIndex(
        in value: String,
        from start: String.Index,
        opening: Character,
        closing: Character
    ) -> String.Index? {
        var depth = 0
        var index = start
        while index < value.endIndex {
            let character = value[index]
            if character == opening {
                depth += 1
            } else if character == closing {
                depth -= 1
                if depth == 0 { return index }
            }
            index = value.index(after: index)
        }
        return nil
    }

    private nonisolated static func matchingOpeningIndex(
        in value: String,
        from end: String.Index,
        opening: Character,
        closing: Character
    ) -> String.Index? {
        var depth = 0
        var index = end
        while true {
            let character = value[index]
            if character == closing {
                depth += 1
            } else if character == opening {
                depth -= 1
                if depth == 0 { return index }
            }
            guard index > value.startIndex else { return nil }
            index = value.index(before: index)
        }
    }

    private nonisolated static func isNoiseBracketContent(_ value: String) -> Bool {
        let normalized = normalizedText(value)
        let compact = canonicalKey(normalized)
        if compact.isEmpty { return true }
        if normalized.range(
            of: #"^(?:19|20)\d{2}(?:[./-]\d{1,2}){0,2}$"#,
            options: .regularExpression
        ) != nil {
            return true
        }
        if normalized.range(of: technicalNoisePattern, options: [.regularExpression, .caseInsensitive]) != nil {
            return true
        }
        if normalized.range(
            of: #"(?:版|唱片|压制|壓制|银圈|銀圈|胶圈|膠圈|金碟|母盘|母盤|母带|母帶|复黑|復黑|限量|限定|珍藏|典藏|收藏|套装|套裝|首批|首版|再版|复刻|復刻|发行|發行|引进|引進|IFPI|原抓|抓轨|抓軌|整轨|整軌|分轨|分軌|无损|無損|华纳|華納|环球|環球|滚石|滾石|飞碟|飛碟|宝丽金|寶麗金|百代|remaster(?:ed)?|deluxe|anniversary|limited\s*edition)"#,
            options: [.regularExpression, .caseInsensitive]
        ) != nil {
            return true
        }
        if normalized.range(
            of: #"(?i)^vol(?:ume)?\.?\s*\d+$"#,
            options: .regularExpression
        ) != nil {
            return true
        }
        return standaloneNoiseBracketKeys.contains(compact)
    }

    private nonisolated static func isLeadingNoiseBracketContent(_ value: String) -> Bool {
        let normalized = normalizedText(value)
        if normalized.range(
            of: #"^[（(]?(?:19|20)\d{2}[）)]?\s+\S"#,
            options: .regularExpression
        ) != nil {
            return false
        }
        return isNoiseBracketContent(normalized)
    }

    private nonisolated static func firstCapturedGroup(
        in value: String,
        pattern: String
    ) -> String? {
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return nil }
        let range = NSRange(value.startIndex..<value.endIndex, in: value)
        guard let match = regex.firstMatch(in: value, range: range),
              match.numberOfRanges >= 2,
              let captureRange = Range(match.range(at: 1), in: value) else {
            return nil
        }
        let captured = trimmedEdgeSeparators(
            in: normalizedWhitespace(String(value[captureRange]))
        )
        return meaningful(captured) ? captured : nil
    }

    private nonisolated static let edgeSeparators = CharacterSet(
        charactersIn: " \t\r\n-_.—–·•|／/\\+"
    )

    private nonisolated static let bracketPairs: [Character: Character] = [
        "[": "]", "【": "】", "(": ")", "（": "）", "{": "}", "《": "》", "〈": "〉"
    ]

    private nonisolated static let closingBracketPairs: [Character: Character] = [
        "]": "[", "】": "【", ")": "(", "）": "（", "}": "{", "》": "《", "〉": "〈"
    ]

    private nonisolated static let technicalNoisePattern = #"(?i)(?:^|[^a-z0-9])(?:wav|flac|ape|dsd|dff|dsf|mp3|m4a|aac|alac|aiff?|sacd(?:iso)?|shm(?:-?cd)?|uhqcd|hqcd|xrcd|k2hd|lpcd(?:45)?|hdcd|cue|hi[ -]?res|lossless|qobuz|tidal|mora|amazon|amz|sony)(?:$|[^a-z0-9])|^(?:flac|wav|dsd|dsf)?(?:16|20|24|32)(?:bit|b)?(?:44(?:\.1)?|48|88(?:\.2)?|96|176(?:\.4)?|192|352(?:\.8)?|384)(?:k?hz)?$|^(?:16|20|24|32)\s*(?:bit|b)?\s*[-_/ ]?\s*(?:44(?:\.1)?|48|88(?:\.2)?|96|176(?:\.4)?|192|352(?:\.8)?|384)(?:\s*k?hz)?$|^\d\s*bit\s*\d(?:\.\d+)?\s*mhz$|^\d{4}(?:\.1)?$|^(?:\d+\s*)?(?:cd|disc|disk)\s*(?:\d+|[a-z])?$"#

    private nonisolated static let trailingNoisePatterns = [
        #"\s*(?:[-–—]\s*)?(?:(?:wav|flac|ape|dsd|dff|dsf|mp3|m4a|aac|alac|aiff?|sacd(?:iso)?|shm(?:-?cd)?|uhqcd|hqcd|xrcd|k2hd|lpcd(?:45)?|hdcd|cue))(?:\s*(?:[+/|]|\s)\s*(?:wav|flac|ape|dsd|dff|dsf|mp3|m4a|aac|alac|aiff?|sacd(?:iso)?|shm(?:-?cd)?|uhqcd|hqcd|xrcd|k2hd|lpcd(?:45)?|hdcd|cue))*\s*$"#,
        #"\s*(?:[-–—]\s*)?(?:(?:flac|wav|dsd|dff|dsf)?\s*(?:16|20|24|32)\s*(?:bit|b)?\s*[-_/ ]?\s*(?:44(?:\.1)?|48|88(?:\.2)?|96|176(?:\.4)?|192|352(?:\.8)?|384)(?:\s*k?hz)?|(?:44\.1|48|88\.2|96|176\.4|192|352\.8|384)\s+(?:16|20|24|32)|1\s*bit\s+\d(?:\.\d+)?\s*mhz|(?:16|24|32)(?:44|48|96|192)|1644(?:\.1)?|2448|2496)\s*$"#,
        #"\s+(?:19|20)\d{2}(?:年)?\s*$"#,
        #"\s+(?:\d+\s*)?(?:cd|disc|disk)\s*(?:\d+|[a-z])?\s*$"#,
        #"\s+(?:第一版|首版|头版|頭版|再版|复刻版|復刻版|限量版|限定版|珍藏版|典藏版|特别版|特別版|完整版)(?:\s.*)?$"#,
        #"\s+(?:韩德银圈版|韓德銀圈版|(?:香港|台湾|臺灣|日本|韩国|韓國|德国|德國|美国|美國|内地|內地|大陆|大陸|新加坡|马来西亚|馬來西亞).*(?:版|压制|壓制|银圈|銀圈|胶圈|膠圈|IFPI))\s*$"#,
        #"\s+(?:(?:飞碟|飛碟|华纳|華納|环球|環球|滚石|滾石|宝丽金|寶麗金|百代|EMI|Sony|ABC|常喜|风林|風林|东升|東升)(?:唱片|音乐|音樂)?)(?:\s.*)?$"#,
        #"\s+(?:\d+[:：]\d+\s*)?(?:母盘|母盤|母带|母帶|原抓|抓轨|抓軌|整轨|整軌|分轨|分軌|无损|無損).*$"#,
        #"\s+(?:remaster(?:ed)?|deluxe|anniversary|limited\s*edition)\s*$"#
    ]

    private nonisolated static let standaloneNoiseBracketKeys: Set<String> = [
        "qobuz", "tidal", "sony", "mora", "amazon", "amz", "hires", "mq", "mqs", "m", "cm",
        "台湾", "台版", "香港", "港版", "日本", "韩国", "德国", "美国", "内地", "大陆",
        "新宝艺", "环球", "华纳", "滚石", "飞碟", "宝丽金", "华星", "百代", "广东音像", "风林", "常喜唱片",
        "wav", "flac", "ape", "dsd", "dff", "dsf", "sacd", "sacdiso", "cue"
    ]

    private nonisolated static let placeholderAlbumNames: Set<String> = [
        "cdimage", "unknown", "unknownalbum", "unknowntitle", "未知专辑", "未分类专辑", "未命名专辑", "track", "audio", "cd", "disc"
    ]
}
