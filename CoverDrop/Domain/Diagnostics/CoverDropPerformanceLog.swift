import Foundation

enum CoverDropPerformanceOutcome: String, Sendable {
    case success
    case failure
    case cancelled
}

struct CoverDropPerformanceSpan: Sendable {
    let operation: String
    let spanID: String
    let startedAt: ContinuousClock.Instant
    let initialContext: [String: String]

    nonisolated func finish(
        outcome: CoverDropPerformanceOutcome = .success,
        context: @autoclosure () -> [String: String] = [:]
    ) {
        CoverDropPerformanceLog.finish(
            self,
            outcome: outcome,
            context: context()
        )
    }
}

enum CoverDropPerformanceOperation {
    nonisolated static let buildCoverWall = "构建封面墙展示数据"
    nonisolated static let openAlbumDetail = "打开详情"
    nonisolated static let returnToCoverWall = "返回封面墙"
    nonisolated static let loadCoverThumbnail = "加载封面缩略图"
    nonisolated static let openAggregateSearch = "打开聚合搜索"
    nonisolated static let aggregateSearchRequest = "聚合搜索请求"
    nonisolated static let readDroppedImage = "读取拖入图片"
    nonisolated static let stageCoverImage = "暂存封面图片"
    nonisolated static let saveCoverImage = "保存封面图片"
    nonisolated static let updateAlbumCover = "更新专辑封面记录"
    nonisolated static let updateScanSnapshot = "更新扫描快照"
    nonisolated static let checkAlbumFolder = "检查专辑目录"
    nonisolated static let mainThreadStall = "主线程响应延迟"
}

enum CoverDropPerformanceLog {
    nonisolated static func begin(
        _ operation: String,
        context: @autoclosure () -> [String: String] = [:]
    ) -> CoverDropPerformanceSpan? {
        beginForTesting(
            operation,
            enabled: isEnabled(environment: ProcessInfo.processInfo.environment),
            context: context
        )
    }

    nonisolated static func beginForTesting(
        _ operation: String,
        enabled: Bool,
        context: () -> [String: String]
    ) -> CoverDropPerformanceSpan? {
        guard enabled else { return nil }
        let span = CoverDropPerformanceSpan(
            operation: operation,
            spanID: UUID().uuidString,
            startedAt: .now,
            initialContext: context()
        )
        writeLine(startLine(
            operation: span.operation,
            spanID: span.spanID,
            thread: threadName,
            context: span.initialContext
        ))
        return span
    }

    nonisolated static func isEnabled(environment: [String: String]) -> Bool {
        environment["COVERDROP_DEBUG_LOG"] == "1"
    }

    nonisolated static func finish(
        _ span: CoverDropPerformanceSpan,
        outcome: CoverDropPerformanceOutcome,
        context: [String: String]
    ) {
        let milliseconds = durationMilliseconds(from: span.startedAt, to: .now)
        writeLine(endLine(
            operation: span.operation,
            spanID: span.spanID,
            durationMilliseconds: milliseconds,
            thread: threadName,
            outcome: outcome,
            context: span.initialContext.merging(context) { _, new in new }
        ))
    }

    nonisolated static func shouldReport(
        durationMilliseconds: Double,
        outcome: CoverDropPerformanceOutcome,
        thresholdMilliseconds: Double
    ) -> Bool {
        outcome != .success || durationMilliseconds >= thresholdMilliseconds
    }

    nonisolated static func makeMainThreadStallMonitor(
        thresholdMilliseconds: Double = 50,
        pollIntervalMilliseconds: Double = 250
    ) -> Task<Void, Never>? {
        guard isEnabled(environment: ProcessInfo.processInfo.environment) else {
            return nil
        }

        return Task.detached(priority: .utility) {
            let pollNanoseconds = UInt64(max(1, pollIntervalMilliseconds) * 1_000_000)
            while !Task.isCancelled {
                do {
                    try await Task.sleep(nanoseconds: pollNanoseconds)
                } catch {
                    break
                }

                let startedAt = ContinuousClock.now
                await runMainQueueProbe {}
                let duration = durationMilliseconds(from: startedAt, to: .now)
                guard shouldReport(
                    durationMilliseconds: duration,
                    outcome: .success,
                    thresholdMilliseconds: thresholdMilliseconds
                ) else {
                    continue
                }

                writeLine(endLine(
                    operation: CoverDropPerformanceOperation.mainThreadStall,
                    spanID: UUID().uuidString,
                    durationMilliseconds: duration,
                    thread: "main",
                    outcome: .success,
                    context: ["threshold": String(format: "%.0fms", thresholdMilliseconds)]
                ))
            }
        }
    }

    nonisolated static func runMainQueueProbe<Value: Sendable>(
        _ operation: @escaping @Sendable () -> Value
    ) async -> Value {
        await withCheckedContinuation { continuation in
            DispatchQueue.main.async {
                continuation.resume(returning: operation())
            }
        }
    }

    nonisolated static func startLine(
        operation: String,
        spanID: String,
        thread: String,
        context: [String: String]
    ) -> String {
        appendContext(
            to: "[性能] 开始 operation=\(sanitized(operation)) span=\(sanitized(spanID)) thread=\(sanitized(thread))",
            context: context
        )
    }

    nonisolated static func writeLine(_ line: String) {
        FileHandle.standardError.write(Data("\(line)\n".utf8))
    }

    nonisolated static func endLine(
        operation: String,
        spanID: String,
        durationMilliseconds: Double,
        thread: String,
        outcome: CoverDropPerformanceOutcome,
        context: [String: String]
    ) -> String {
        appendContext(
            to: "[性能] 结束 operation=\(sanitized(operation)) span=\(sanitized(spanID)) duration=\(String(format: "%.2f", durationMilliseconds))ms thread=\(sanitized(thread)) outcome=\(outcome.rawValue)",
            context: context
        )
    }

    nonisolated private static var threadName: String {
        Thread.isMainThread ? "main" : "background"
    }

    nonisolated private static func durationMilliseconds(
        from start: ContinuousClock.Instant,
        to end: ContinuousClock.Instant
    ) -> Double {
        let components = start.duration(to: end).components
        return Double(components.seconds) * 1_000
            + Double(components.attoseconds) / 1_000_000_000_000_000
    }

    nonisolated private static func sanitized(_ value: String) -> String {
        value
            .components(separatedBy: .whitespacesAndNewlines)
            .filter { !$0.isEmpty }
            .joined(separator: "_")
    }

    nonisolated private static func appendContext(
        to line: String,
        context: [String: String]
    ) -> String {
        let suffix = context.keys.sorted().map { key in
            "\(sanitized(key))=\(sanitized(context[key] ?? ""))"
        }.joined(separator: " ")
        guard !suffix.isEmpty else { return line }
        return "\(line) \(suffix)"
    }
}
