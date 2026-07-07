import Foundation

struct OllamaAlbumNameSuggesting: AlbumNameSuggestingResourceReleasing {
    private let baseURL: String
    private let endpointURL: URL?
    private let model: String
    private let requestTimeoutSeconds: TimeInterval
    private let keepAlive: String?
    private let session: URLSession

    init(
        baseURL: String,
        model: String,
        requestTimeoutSeconds: TimeInterval,
        keepAlive: String? = nil,
        session: URLSession? = nil
    ) {
        let trimmedBaseURL = baseURL.trimmingCharacters(in: .whitespacesAndNewlines)
        if let url = URL(string: trimmedBaseURL),
           let scheme = url.scheme,
           ["http", "https"].contains(scheme.lowercased()) {
            self.endpointURL = url
        } else {
            self.endpointURL = nil
        }
        self.baseURL = trimmedBaseURL
        self.model = model
        self.requestTimeoutSeconds = max(1, requestTimeoutSeconds)
        self.keepAlive = keepAlive
        if let session {
            self.session = session
        } else {
            let configuration = URLSessionConfiguration.default
            configuration.timeoutIntervalForRequest = self.requestTimeoutSeconds
            configuration.timeoutIntervalForResource = self.requestTimeoutSeconds + 30
            self.session = URLSession(configuration: configuration)
        }
    }

    func releaseResources() async {
        guard let endpointURL else { return }

        do {
            let requestBody = OllamaChatRequest(
                model: model,
                messages: [],
                think: nil,
                stream: false,
                format: nil,
                keepAlive: "0"
            )
            let requestData = try JSONEncoder().encode(requestBody)
            let requestURL = endpointURL.appendingPathComponent("api").appendingPathComponent("chat")
            var request = URLRequest(url: requestURL, timeoutInterval: min(requestTimeoutSeconds, 30))
            request.httpMethod = "POST"
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            request.setValue("application/json", forHTTPHeaderField: "Accept")
            request.httpBody = requestData

            let (_, response) = try await session.data(for: request)
            try validateHTTPResponse(response)
            CoverDropDebugLog.write("Ollama 名称增强：批处理结束，已请求释放模型资源，模型=\(model)")
        } catch {
            CoverDropDebugLog.write("Ollama 名称增强：释放模型资源失败，模型=\(model)，原因=\(error.localizedDescription)")
        }
    }

    func suggestAlbumName(for input: AlbumNameEnhancementInput) async throws -> AlbumNameSuggestion {
        let request = try makeRequest(for: input)
        let requestStartedAt = Date()
        CoverDropDebugLog.write(
            "Ollama 名称增强：开始请求，URL=\(request.url?.absoluteString ?? "无")，模型=\(model)，think=false，超时=\(Int(requestTimeoutSeconds))秒，专辑路径=\(input.albumRelativePath)，原始歌手=\(input.originalArtistName)，原始专辑=\(input.originalAlbumName)，曲目数=\(input.audioFiles.count)，请求大小=\(request.httpBody?.count ?? 0) bytes"
        )
        let modelContent = try await receiveStreamingContent(
            for: request,
            requestStartedAt: requestStartedAt
        )

        CoverDropDebugLog.write("Ollama 名称增强：模型输出内容片段=\(preview(text: modelContent))")

        do {
            let suggestion = try AlbumNameSuggestionParser.parse(content: modelContent)
            CoverDropDebugLog.write(
                "Ollama 名称增强：解析成功，\(input.originalArtistName) / \(input.originalAlbumName) -> \(suggestion.artistName) / \(suggestion.albumName)，总耗时=\(formatDuration(since: requestStartedAt))"
            )
            return suggestion
        } catch {
            CoverDropDebugLog.write(
                "Ollama 名称增强：模型内容解析失败，错误=\(error.localizedDescription)，内容片段=\(preview(text: modelContent))"
            )
            throw error
        }
    }

    private func makeRequest(for input: AlbumNameEnhancementInput) throws -> URLRequest {
        guard let endpointURL else {
            throw OllamaAlbumNameSuggestingError.invalidBaseURL(baseURL)
        }

        let requestBody = OllamaChatRequest(
            model: model,
            messages: [
                .system(Self.systemPrompt),
                .user(Self.userPrompt(for: input))
            ],
            think: false,
            stream: true,
            format: .jsonSchema(Self.responseSchema),
            keepAlive: keepAlive
        )

        let requestData = try JSONEncoder().encode(requestBody)
        let requestURL = endpointURL.appendingPathComponent("api").appendingPathComponent("chat")
        var request = URLRequest(url: requestURL, timeoutInterval: requestTimeoutSeconds)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.httpBody = requestData
        return request
    }

    private func receiveStreamingContent(
        for request: URLRequest,
        requestStartedAt: Date
    ) async throws -> String {
        let bytes: URLSession.AsyncBytes
        let response: URLResponse
        do {
            (bytes, response) = try await session.bytes(for: request)
        } catch {
            let mappedError = mapTransportError(error, elapsedSeconds: Date().timeIntervalSince(requestStartedAt))
            CoverDropDebugLog.write(
                "Ollama 名称增强：网络层失败，URL=\(request.url?.absoluteString ?? "无")，模型=\(model)，耗时=\(formatDuration(since: requestStartedAt))，错误=\(mappedError.localizedDescription)"
            )
            throw mappedError
        }

        try validateHTTPResponse(response)
        CoverDropDebugLog.write(
            "Ollama 名称增强：已建立流式响应，URL=\(request.url?.absoluteString ?? "无")，模型=\(model)，耗时=\(formatDuration(since: requestStartedAt))，HTTP=\((response as? HTTPURLResponse)?.statusCode.description ?? "非 HTTP")"
        )

        var content = ""
        var receivedLineCount = 0
        var firstChunkAt: Date?
        var thinkingCharacterCount = 0

        do {
            for try await line in bytes.lines {
                guard !line.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                    continue
                }

                receivedLineCount += 1
                firstChunkAt = firstChunkAt ?? Date()
                let chunk: OllamaChatStreamChunk
                do {
                    chunk = try OllamaChatStreamParser.parse(line: line)
                } catch {
                    CoverDropDebugLog.write(
                        "Ollama 名称增强：流式响应解析失败，行=\(receivedLineCount)，错误=\(error.localizedDescription)，原始片段=\(preview(text: line))"
                    )
                    throw error
                }

                if let errorMessage = chunk.errorMessage {
                    CoverDropDebugLog.write(
                        "Ollama 名称增强：流式响应返回错误，行=\(receivedLineCount)，错误=\(errorMessage)，原始片段=\(preview(text: line))"
                    )
                    throw OllamaAlbumNameSuggestingError.requestFailed(message: errorMessage)
                }

                if !chunk.content.isEmpty {
                    content += chunk.content
                }

                if !chunk.thinking.isEmpty {
                    thinkingCharacterCount += chunk.thinking.count
                }

                if receivedLineCount == 1 || chunk.isDone || (!chunk.thinking.isEmpty && receivedLineCount % 100 == 0) {
                    CoverDropDebugLog.write(
                        "Ollama 名称增强：收到流式片段，行=\(receivedLineCount)，done=\(chunk.isDone)，本段内容字符=\(chunk.content.count)，累计内容字符=\(content.count)，累计思考字符=\(thinkingCharacterCount)，思考片段=\(preview(text: chunk.thinking, limit: 160))，内容片段=\(preview(text: chunk.content, limit: 160))，耗时=\(formatDuration(since: requestStartedAt))"
                    )
                }

                if chunk.isDone {
                    CoverDropDebugLog.write(
                        "Ollama 名称增强：流式响应完成，行数=\(receivedLineCount)，首片段耗时=\(firstChunkAt.map { formatDuration(since: requestStartedAt, until: $0) } ?? "无")，总耗时=\(formatDuration(since: requestStartedAt))，累计内容字符=\(content.count)，累计思考字符=\(thinkingCharacterCount)"
                    )
                    guard !content.isEmpty else {
                        throw OllamaAlbumNameSuggestingError.requestFailed(
                            message: "Ollama 已完成流式响应，但没有返回 message.content；模型可能只输出了 thinking 字段或生成长度不足。请查看 Xcode 控制台中的思考片段日志。"
                        )
                    }
                    return content
                }
            }
        } catch let error as OllamaAlbumNameSuggestingError {
            throw error
        } catch {
            let mappedError = mapTransportError(error, elapsedSeconds: Date().timeIntervalSince(requestStartedAt))
            CoverDropDebugLog.write(
                "Ollama 名称增强：读取流式响应失败，行数=\(receivedLineCount)，累计字符=\(content.count)，耗时=\(formatDuration(since: requestStartedAt))，错误=\(mappedError.localizedDescription)"
            )
            throw mappedError
        }

        CoverDropDebugLog.write(
            "Ollama 名称增强：流式响应提前结束，行数=\(receivedLineCount)，累计内容字符=\(content.count)，累计思考字符=\(thinkingCharacterCount)，耗时=\(formatDuration(since: requestStartedAt))"
        )
        guard !content.isEmpty else {
            throw OllamaAlbumNameSuggestingError.invalidResponse
        }
        return content
    }

    private func validateHTTPResponse(_ response: URLResponse) throws {
        guard let httpResponse = response as? HTTPURLResponse else {
            CoverDropDebugLog.write("Ollama 名称增强：响应不是 HTTPURLResponse。")
            throw OllamaAlbumNameSuggestingError.invalidResponse
        }

        guard (200...299).contains(httpResponse.statusCode) else {
            CoverDropDebugLog.write("Ollama 名称增强：HTTP 失败，状态码=\(httpResponse.statusCode)")
            throw OllamaAlbumNameSuggestingError.serverError(statusCode: httpResponse.statusCode, message: nil)
        }
    }

    private func mapTransportError(_ error: Error, elapsedSeconds: TimeInterval) -> Error {
        guard let urlError = error as? URLError else {
            return OllamaAlbumNameSuggestingError.requestFailed(message: error.localizedDescription)
        }

        return OllamaAlbumNameSuggestingError.transportError(
            baseURL: baseURL,
            model: model,
            timeoutSeconds: requestTimeoutSeconds,
            elapsedSeconds: elapsedSeconds,
            code: urlError.code,
            underlyingMessage: urlError.localizedDescription
        )
    }

    private func formatDuration(since startedAt: Date) -> String {
        String(format: "%.2fs", Date().timeIntervalSince(startedAt))
    }

    private func formatDuration(since startedAt: Date, until endedAt: Date) -> String {
        String(format: "%.2fs", endedAt.timeIntervalSince(startedAt))
    }

    private func preview(text: String, limit: Int = 600) -> String {
        let normalized = text
            .replacingOccurrences(of: "\n", with: "\\n")
            .replacingOccurrences(of: "\r", with: "\\r")
        guard normalized.count > limit else { return normalized }
        return "\(normalized.prefix(limit))…"
    }

    private static func userPrompt(for input: AlbumNameEnhancementInput) -> String {
        let inputJSON = (try? JSONEncoder().encode(input))
            .flatMap { String(data: $0, encoding: .utf8) } ?? "{}"

        return """
        输入 JSON：
        \(inputJSON)

        任务：
        - 只从路径和标签里选最可信的真实歌手名、专辑名，用于展示和搜封面。
        - 删除目录噪音：年份/日期前缀、编号壳、CD/Disc、WAV/FLAC/DSD、版本、格式、码率、抓轨、无损、来源站点、尾部套装/系列说明。
        - 尾部括号里如果是发行套装或系列编号，不属于专辑名。例如“林子祥精选集 [百代珍藏套装之7]”应返回“林子祥精选集”。
        - 保留正式专辑名里的数字和英文；中文人名/中文专辑名用简体。
        - 没有依据就返回清理后的原始名称，不要编造。
        - 只输出 JSON：{"artistName":"...","albumName":"..."}
        """
    }

    private static let systemPrompt = """
    你是音乐库封面搜索的名称清洗器，只输出严格 JSON。
    目标：找真实歌手名和真实专辑名；不要决定目录边界，不要改文件。

    删除 albumName 开头的年份、日期、编号壳：
    - "1981 - 林子祥精选集" -> "林子祥精选集"
    - "1984-林子祥创作歌集" -> "林子祥创作歌集"
    - "1988-20 GREATEST HITS" -> "20 GREATEST HITS"
    - "001/专辑名"、"CD1"、"Disc 2"、"WAV"、"FLAC" 不是专辑名

    保留正式名称里的数字：
    - "20 GREATEST HITS" 保留
    - "No.1" 保留
    - "24K Magic" 保留
    - "1989" 如果标签和路径都表明它是专辑名，保留

    删除版本/介质/格式/来源噪音：港版、台版、日本版、首版、复刻版、Deluxe、Remastered、Anniversary、SACD、DSD、WAV、FLAC、MP3、Hi-Res、24bit、96kHz、抓轨、无损、整轨、CUE、网站名。
    删除尾部发行套装/系列说明：
    - "林子祥精选集 [百代珍藏套装之7]" -> "林子祥精选集"
    - "专辑名 [WAV]"、"专辑名 [港版]"、"专辑名 (Remastered)" -> "专辑名"
    英文专辑名保留英文；中文繁体转简体；没有依据就返回清理后的原名。只输出 {"artistName":"...","albumName":"..."}。
    """

    private static let responseSchema = OllamaResponseSchema()
}

private struct OllamaChatRequest: Encodable {
    enum Message: Encodable {
        case system(String)
        case user(String)

        func encode(to encoder: Encoder) throws {
            var container = encoder.container(keyedBy: CodingKeys.self)
            switch self {
            case .system(let content):
                try container.encode("system", forKey: .role)
                try container.encode(content, forKey: .content)
            case .user(let content):
                try container.encode("user", forKey: .role)
                try container.encode(content, forKey: .content)
            }
        }

        private enum CodingKeys: String, CodingKey {
            case role
            case content
        }
    }

    let model: String
    let messages: [Message]
    let think: Bool?
    let stream: Bool
    let format: OllamaResponseFormat?
    let keepAlive: String?

    private enum CodingKeys: String, CodingKey {
        case model
        case messages
        case think
        case stream
        case format
        case keepAlive = "keep_alive"
    }
}

private enum OllamaResponseFormat: Encodable {
    case jsonSchema(OllamaResponseSchema)

    func encode(to encoder: Encoder) throws {
        switch self {
        case .jsonSchema(let schema):
            try schema.encode(to: encoder)
        }
    }
}

private struct OllamaResponseSchema: Encodable {
    let type = "object"
    let properties: [String: OllamaResponseSchemaProperty] = [
        "artistName": OllamaResponseSchemaProperty(type: "string"),
        "albumName": OllamaResponseSchemaProperty(type: "string")
    ]
    let required = ["artistName", "albumName"]
    let additionalProperties = false
}

private struct OllamaResponseSchemaProperty: Encodable {
    let type: String
}

struct OllamaChatStreamChunk: Equatable, Sendable {
    let content: String
    let thinking: String
    let isDone: Bool
    let errorMessage: String?
}

enum OllamaChatStreamParser {
    static func parse(line: String) throws -> OllamaChatStreamChunk {
        let trimmedLine = line.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let data = trimmedLine.data(using: .utf8) else {
            throw OllamaAlbumNameSuggestingError.nonJSONContent
        }

        do {
            let response = try JSONDecoder().decode(OllamaChatStreamResponse.self, from: data)
            return OllamaChatStreamChunk(
                content: response.message?.content ?? "",
                thinking: response.message?.thinking ?? "",
                isDone: response.done ?? false,
                errorMessage: response.error
            )
        } catch {
            throw OllamaAlbumNameSuggestingError.responseDecodingFailed(
                message: error.localizedDescription,
                responsePreview: Self.preview(text: trimmedLine)
            )
        }
    }

    private static func preview(text: String, limit: Int = 600) -> String {
        let normalized = text
            .replacingOccurrences(of: "\n", with: "\\n")
            .replacingOccurrences(of: "\r", with: "\\r")
        guard normalized.count > limit else { return normalized }
        return "\(normalized.prefix(limit))…"
    }
}

private struct OllamaChatStreamResponse: Decodable {
    struct Message: Decodable {
        let content: String?
        let thinking: String?
    }

    let message: Message?
    let done: Bool?
    let error: String?
}

enum AlbumNameSuggestionParser {
    static func parse(content: String) throws -> AlbumNameSuggestion {
        var lastDecodingError: Error?
        for candidate in jsonCandidates(from: content) {
            guard let data = candidate.data(using: .utf8) else {
                continue
            }

            do {
                let object = try JSONSerialization.jsonObject(with: data)
                guard let dictionary = object as? [String: Any] else {
                    lastDecodingError = OllamaAlbumNameSuggestingError.nonJSONContent
                    continue
                }

                guard let artistName = trimmedString(from: dictionary["artistName"]),
                      let albumName = trimmedString(from: dictionary["albumName"]) else {
                    throw OllamaAlbumNameSuggestingError.invalidPayload
                }

                return AlbumNameSuggestionCleaner.clean(
                    AlbumNameSuggestion(artistName: artistName, albumName: albumName)
                )
            } catch let error as OllamaAlbumNameSuggestingError {
                throw error
            } catch {
                lastDecodingError = error
            }
        }

        throw OllamaAlbumNameSuggestingError.responseDecodingFailed(
            message: lastDecodingError?.localizedDescription ?? "未找到可解析的 JSON 对象",
            responsePreview: preview(text: content)
        )
    }

    private static func trimmedString(from value: Any?) -> String? {
        guard let string = value as? String else { return nil }
        let trimmed = string.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    private static func jsonCandidates(from content: String) -> [String] {
        let trimmed = content.trimmingCharacters(in: .whitespacesAndNewlines)
        var candidates: [String] = []
        append(trimmed, to: &candidates)

        for fencedContent in markdownCodeFenceContents(from: trimmed) {
            append(fencedContent, to: &candidates)
        }

        if let objectText = firstJSONObjectText(in: trimmed) {
            append(objectText, to: &candidates)
        }

        return candidates
    }

    private static func append(_ candidate: String, to candidates: inout [String]) {
        let trimmed = candidate.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, !candidates.contains(trimmed) else { return }
        candidates.append(trimmed)
    }

    private static func markdownCodeFenceContents(from content: String) -> [String] {
        let lines = content.components(separatedBy: .newlines)
        var fencedContents: [String] = []
        var bodyLines: [String]?

        for line in lines {
            let trimmedLine = line.trimmingCharacters(in: .whitespacesAndNewlines)
            if trimmedLine.hasPrefix("```") {
                if let currentBodyLines = bodyLines {
                    append(currentBodyLines.joined(separator: "\n"), to: &fencedContents)
                    bodyLines = nil
                } else {
                    bodyLines = []
                    let suffix = String(trimmedLine.dropFirst(3))
                        .trimmingCharacters(in: .whitespacesAndNewlines)
                    if suffix.hasPrefix("{") {
                        bodyLines?.append(suffix)
                    }
                }
            } else if bodyLines != nil {
                bodyLines?.append(line)
            }
        }

        if let currentBodyLines = bodyLines {
            append(currentBodyLines.joined(separator: "\n"), to: &fencedContents)
        }

        return fencedContents
    }

    private static func firstJSONObjectText(in content: String) -> String? {
        guard let startIndex = content.firstIndex(of: "{") else { return nil }

        var depth = 0
        var isInsideString = false
        var isEscaped = false
        var index = startIndex

        while index < content.endIndex {
            let character = content[index]

            if isInsideString {
                if isEscaped {
                    isEscaped = false
                } else if character == "\\" {
                    isEscaped = true
                } else if character == "\"" {
                    isInsideString = false
                }
            } else if character == "\"" {
                isInsideString = true
            } else if character == "{" {
                depth += 1
            } else if character == "}" {
                depth -= 1
                if depth == 0 {
                    return String(content[startIndex...index])
                }
            }

            index = content.index(after: index)
        }

        return nil
    }

    private static func preview(text: String, limit: Int = 600) -> String {
        let normalized = text
            .replacingOccurrences(of: "\n", with: "\\n")
            .replacingOccurrences(of: "\r", with: "\\r")
        guard normalized.count > limit else { return normalized }
        return "\(normalized.prefix(limit))…"
    }
}

enum AlbumNameSuggestionCleaner {
    static func clean(_ suggestion: AlbumNameSuggestion) -> AlbumNameSuggestion {
        AlbumNameSuggestion(
            artistName: normalizedWhitespace(suggestion.artistName),
            albumName: cleanAlbumName(suggestion.albumName)
        )
    }

    static func cleanAlbumName(_ albumName: String) -> String {
        var normalized = normalizedWhitespace(albumName)
        let patterns = [
            #"^\s*(?:19|20)\d{6}\s*[-_—–. ]+\s*(\S.*)$"#,
            #"^\s*(?:19|20)\d{2}\s*年\s*[-_—–. ]*\s*(\S.*)$"#,
            #"^\s*(?:19|20)\d{2}\s*[-_—–. ]+\s*(\S.*)$"#
        ]

        for pattern in patterns {
            if let cleaned = firstCapturedGroup(in: normalized, pattern: pattern) {
                normalized = normalizedWhitespace(cleaned)
                break
            }
        }

        return stripTrailingNoiseBracketGroups(from: normalized)
    }

    private static func stripTrailingNoiseBracketGroups(from value: String) -> String {
        var current = value

        while let group = trailingBracketGroup(in: current),
              isNoiseBracketContent(group.content) {
            current = String(current[..<group.range.lowerBound])
                .trimmingCharacters(in: .whitespacesAndNewlines)
        }

        return current.isEmpty ? value : normalizedWhitespace(current)
    }

    private static func trailingBracketGroup(in value: String) -> (content: String, range: Range<String.Index>)? {
        let closingToOpening: [Character: Character] = [
            "]": "[",
            ")": "(",
            "）": "（",
            "】": "【"
        ]

        let trimmedEnd = value.lastIndex { !$0.isWhitespace } ?? value.startIndex
        guard trimmedEnd < value.endIndex,
              let opening = closingToOpening[value[trimmedEnd]] else {
            return nil
        }

        var index = value.index(before: trimmedEnd)
        while true {
            if value[index] == opening {
                let contentStart = value.index(after: index)
                let content = String(value[contentStart..<trimmedEnd])
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                return content.isEmpty ? nil : (content, index..<value.index(after: trimmedEnd))
            }

            if index == value.startIndex {
                break
            }
            index = value.index(before: index)
        }

        return nil
    }

    private static func isNoiseBracketContent(_ value: String) -> Bool {
        let normalized = normalizedWhitespace(value)
            .lowercased()
            .replacingOccurrences(of: " ", with: "")
            .replacingOccurrences(of: "-", with: "")
            .replacingOccurrences(of: "_", with: "")
            .replacingOccurrences(of: ".", with: "")
        let noiseTokens = [
            "套装", "套裝", "珍藏", "百代珍藏", "系列", "合集", "合辑", "合輯",
            "wav", "flac", "dsd", "dff", "ape", "mp3", "sacd", "cue",
            "hires", "24bit", "16bit", "96khz", "192khz",
            "无损", "無損", "抓轨", "抓軌", "整轨", "整軌",
            "港版", "台版", "臺版", "日本版", "首版", "复刻", "復刻", "再版",
            "remaster", "remastered", "deluxe", "anniversary", "limitededition"
        ]

        if noiseTokens.contains(where: { normalized.contains($0) }) {
            return true
        }

        return normalized.range(of: #"^vol(?:ume)?\d+$"#, options: .regularExpression) != nil ||
            normalized.range(of: #"^(?:cd|disc|disk)\d+$"#, options: .regularExpression) != nil ||
            normalized.range(of: #"^之\d+$"#, options: .regularExpression) != nil
    }

    private static func normalizedWhitespace(_ value: String) -> String {
        value
            .components(separatedBy: .whitespacesAndNewlines)
            .filter { !$0.isEmpty }
            .joined(separator: " ")
    }

    private static func firstCapturedGroup(in value: String, pattern: String) -> String? {
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return nil }
        let range = NSRange(value.startIndex..<value.endIndex, in: value)
        guard let match = regex.firstMatch(in: value, range: range),
              match.numberOfRanges >= 2,
              let captureRange = Range(match.range(at: 1), in: value) else {
            return nil
        }

        let captured = String(value[captureRange])
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return captured.isEmpty ? nil : captured
    }
}

enum OllamaAlbumNameSuggestingError: LocalizedError, Sendable {
    case invalidBaseURL(String)
    case invalidResponse
    case serverError(statusCode: Int, message: String?)
    case nonJSONContent
    case invalidPayload
    case responseDecodingFailed(message: String, responsePreview: String)
    case transportError(
        baseURL: String,
        model: String,
        timeoutSeconds: TimeInterval,
        elapsedSeconds: TimeInterval,
        code: URLError.Code,
        underlyingMessage: String
    )
    case requestFailed(message: String)

    var errorDescription: String? {
        switch self {
        case .invalidBaseURL(let value):
            return "Ollama 基础地址无效：\(value)"
        case .invalidResponse:
            return "Ollama 返回了无效响应。"
        case .serverError(let statusCode, let message):
            if statusCode == 404,
               let message,
               let modelName = Self.missingModelName(from: message) {
                return "Ollama 模型不存在：\(modelName)"
            }

            if let message, !message.isEmpty {
                return "Ollama 请求失败（\(statusCode)）：\(message)"
            }
            return "Ollama 请求失败（\(statusCode)）。"
        case .nonJSONContent:
            return "Ollama 返回内容不是有效 JSON。"
        case .invalidPayload:
            return "Ollama 返回的 JSON 缺少 artistName 或 albumName。"
        case .responseDecodingFailed(let message, let responsePreview):
            return "Ollama 响应解析失败：\(message)。响应片段：\(responsePreview)"
        case .transportError(let baseURL, let model, let timeoutSeconds, let elapsedSeconds, let code, let underlyingMessage):
            switch code {
            case .timedOut:
                return "Ollama 请求超时：已等待 \(Self.secondsText(elapsedSeconds))，超时设置 \(Self.secondsText(timeoutSeconds))，模型 \(model)，地址 \(baseURL)。如果 GPU 正在满载，模型可能仍在生成；请查看 Xcode 控制台中的“Ollama 名称增强”日志。底层错误：\(underlyingMessage)"
            case .cannotConnectToHost, .cannotFindHost:
                return "无法连接到 Ollama：地址 \(baseURL)，模型 \(model)。请确认本地服务已启动。底层错误：\(underlyingMessage)"
            case .networkConnectionLost:
                return "连接 Ollama 时网络中断：地址 \(baseURL)，模型 \(model)。底层错误：\(underlyingMessage)"
            default:
                return "Ollama 请求失败：地址 \(baseURL)，模型 \(model)，URLError=\(code.rawValue)，底层错误：\(underlyingMessage)"
            }
        case .requestFailed(let message):
            return "Ollama 请求失败：\(message)"
        }
    }

    private static func secondsText(_ seconds: TimeInterval) -> String {
        "\(Int(seconds.rounded())) 秒"
    }

    private static func missingModelName(from message: String) -> String? {
        let pattern = #"model ['"]([^'"]+)['"] not found"#
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return nil }
        let range = NSRange(message.startIndex..<message.endIndex, in: message)
        guard let match = regex.firstMatch(in: message, range: range),
              match.numberOfRanges >= 2,
              let modelRange = Range(match.range(at: 1), in: message) else {
            return nil
        }
        return String(message[modelRange])
    }
}
