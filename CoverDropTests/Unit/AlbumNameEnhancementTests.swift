import Foundation
import Testing
@testable import CoverDrop

struct AlbumNameEnhancementTests {
    @Test("Ollama 流式内容片段可以正确解析")
    func parsesOllamaStreamContentChunk() throws {
        let chunk = try OllamaChatStreamParser.parse(
            line: #"{"model":"qwen3.5:4b-mlx","message":{"role":"assistant","content":"{\"artistName\":\"周杰伦\""},"done":false}"#
        )

        #expect(chunk.content == #"{"artistName":"周杰伦""#)
        #expect(chunk.thinking == "")
        #expect(chunk.isDone == false)
        #expect(chunk.errorMessage == nil)
    }

    @Test("Ollama 流式思考片段可以正确解析")
    func parsesOllamaStreamThinkingChunk() throws {
        let chunk = try OllamaChatStreamParser.parse(
            line: #"{"model":"qwen3.5:4b-mlx","message":{"role":"assistant","content":"","thinking":"正在判断专辑名"},"done":false}"#
        )

        #expect(chunk.content == "")
        #expect(chunk.thinking == "正在判断专辑名")
        #expect(chunk.isDone == false)
        #expect(chunk.errorMessage == nil)
    }

    @Test("Ollama 流式完成片段可以正确解析")
    func parsesOllamaStreamDoneChunk() throws {
        let chunk = try OllamaChatStreamParser.parse(
            line: #"{"model":"qwen3.5:4b-mlx","message":{"role":"assistant","content":""},"done":true}"#
        )

        #expect(chunk.content == "")
        #expect(chunk.thinking == "")
        #expect(chunk.isDone)
        #expect(chunk.errorMessage == nil)
    }

    @Test("Ollama 流式错误片段保留错误信息")
    func parsesOllamaStreamErrorChunk() throws {
        let chunk = try OllamaChatStreamParser.parse(
            line: #"{"error":"model not found"}"#
        )

        #expect(chunk.content == "")
        #expect(chunk.thinking == "")
        #expect(chunk.isDone == false)
        #expect(chunk.errorMessage == "model not found")
    }

    @Test("Ollama 返回的 JSON 可以正确解码")
    func parsesValidOllamaJSON() throws {
        let suggestion = try AlbumNameSuggestionParser.parse(
            content: #"{"artistName":"周杰伦","albumName":"七里香"}"#
        )

        #expect(suggestion.artistName == "周杰伦")
        #expect(suggestion.albumName == "七里香")
    }

    @Test("Ollama 返回 Markdown JSON 代码块时也可以解码")
    func parsesMarkdownFencedOllamaJSON() throws {
        let suggestion = try AlbumNameSuggestionParser.parse(
            content: """
            ```json
            {
              "artistName": "郑秀文",
              "albumName": "Becoming Sammi"
            }
            ```
            """
        )

        #expect(suggestion.artistName == "郑秀文")
        #expect(suggestion.albumName == "Becoming Sammi")
    }

    @Test("Ollama 返回说明文字夹着 JSON 时也可以解码")
    func parsesOllamaJSONInsideExtraText() throws {
        let suggestion = try AlbumNameSuggestionParser.parse(
            content: """
            结果如下：
            {"artistName":"郑秀文","albumName":"Becoming Sammi"}
            """
        )

        #expect(suggestion.artistName == "郑秀文")
        #expect(suggestion.albumName == "Becoming Sammi")
    }

    @Test("Ollama 返回说明文字夹着 Markdown JSON 代码块时也可以解码")
    func parsesFencedOllamaJSONInsideExtraText() throws {
        let suggestion = try AlbumNameSuggestionParser.parse(
            content: """
            这是清理后的结果：
            ```json
            {
              "artistName": "郑秀文",
              "albumName": "Becoming Sammi"
            }
            ```
            """
        )

        #expect(suggestion.artistName == "郑秀文")
        #expect(suggestion.albumName == "Becoming Sammi")
    }

    @Test("Ollama 返回额外字段时忽略额外字段")
    func ignoresExtraOllamaJSONFields() throws {
        let suggestion = try AlbumNameSuggestionParser.parse(
            content: #"{"artistName":"郑秀文","albumName":"Becoming Sammi","note":"来自路径"}"#
        )

        #expect(suggestion.artistName == "郑秀文")
        #expect(suggestion.albumName == "Becoming Sammi")
    }

    @Test("Ollama 返回年份前缀时会清理为核心专辑名")
    func cleansDatePrefixFromOllamaAlbumName() throws {
        let suggestion = try AlbumNameSuggestionParser.parse(
            content: #"{"artistName":"林子祥","albumName":"1981 - 林子祥精选集"}"#
        )
        let greatestHits = try AlbumNameSuggestionParser.parse(
            content: #"{"artistName":"林子祥","albumName":"1988-20 GREATEST HITS"}"#
        )

        #expect(suggestion.albumName == "林子祥精选集")
        #expect(greatestHits.albumName == "20 GREATEST HITS")
    }

    @Test("专辑正式名称里的数字会保留")
    func keepsNumbersThatBelongToAlbumName() throws {
        #expect(AlbumNameSuggestionCleaner.cleanAlbumName("20 GREATEST HITS") == "20 GREATEST HITS")
        #expect(AlbumNameSuggestionCleaner.cleanAlbumName("No.1") == "No.1")
        #expect(AlbumNameSuggestionCleaner.cleanAlbumName("24K Magic") == "24K Magic")
        #expect(AlbumNameSuggestionCleaner.cleanAlbumName("1989") == "1989")
    }

    @Test("尾部套装和格式括号会从专辑名中清理")
    func cleansTrailingBoxSetAndFormatBrackets() throws {
        let suggestion = try AlbumNameSuggestionParser.parse(
            content: #"{"artistName":"林子祥","albumName":"1981-林子祥精选集[百代珍藏套装之7][WAV]"}"#
        )

        #expect(suggestion.albumName == "林子祥精选集")
        #expect(AlbumNameSuggestionCleaner.cleanAlbumName("林子祥精选集 [百代珍藏套装之7]") == "林子祥精选集")
        #expect(AlbumNameSuggestionCleaner.cleanAlbumName("林子祥精选集 (Remastered)") == "林子祥精选集")
        #expect(AlbumNameSuggestionCleaner.cleanAlbumName("No.1") == "No.1")
    }

    @Test("Ollama 返回非 JSON 时解析失败")
    func rejectsNonJSONContent() {
        do {
            _ = try AlbumNameSuggestionParser.parse(content: "not-json")
            #expect(Bool(false))
        } catch {
            #expect(true)
        }
    }

    @Test("Ollama 返回缺字段时解析失败")
    func rejectsMissingFields() {
        do {
            _ = try AlbumNameSuggestionParser.parse(content: #"{"artistName":"周杰伦"}"#)
            #expect(Bool(false))
        } catch {
            #expect(true)
        }
    }

    @Test("Ollama 返回空字段时解析失败")
    func rejectsEmptyFields() {
        do {
            _ = try AlbumNameSuggestionParser.parse(content: #"{"artistName":" ","albumName":"七里香"}"#)
            #expect(Bool(false))
        } catch {
            #expect(true)
        }
    }

    @Test("增强输入最多只包含前 12 首曲目")
    func inputBuilderLimitsTrackCountToTwelve() {
        let albumFolder = URL(fileURLWithPath: "/Volumes/Music/周杰伦/七里香", isDirectory: true)
        let audioFiles = (1...15).map { index in
            AudioFileRecord(
                url: albumFolder.appendingPathComponent(String(format: "%02d.flac", index)),
                relativePath: String(format: "%02d.flac", index),
                format: "flac",
                metadata: AudioMetadata(
                    title: "Track \(index)",
                    artist: "周杰伦",
                    albumArtist: "周杰伦",
                    album: "七里香",
                    discNumber: nil,
                    trackNumber: index,
                    durationSeconds: nil
                ),
                readError: nil
            )
        }
        let album = AlbumScanRecord(
            folderURL: albumFolder,
            artistName: "周杰伦",
            albumName: "七里香",
            audioFiles: audioFiles,
            displayedCover: nil,
            issues: []
        )

        let input = AlbumNameEnhancementInputBuilder.makeInput(
            for: album,
            libraryRootPath: "/Volumes/Music",
            maxTracks: 12
        )

        #expect(input.albumRelativePath == "周杰伦/七里香")
        #expect(input.audioFiles.count == 12)
        #expect(input.audioFiles.last?.relativePath == "12.flac")
    }
}
