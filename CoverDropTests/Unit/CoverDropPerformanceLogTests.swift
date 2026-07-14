import Foundation
import Testing
@testable import CoverDrop

struct CoverDropPerformanceLogTests {
    @Test("只有值为 1 的环境变量启用性能日志")
    func environmentFlagMustEqualOne() {
        #expect(CoverDropPerformanceLog.isEnabled(environment: [:]) == false)
        #expect(CoverDropPerformanceLog.isEnabled(environment: ["COVERDROP_DEBUG_LOG": "0"]) == false)
        #expect(CoverDropPerformanceLog.isEnabled(environment: ["COVERDROP_DEBUG_LOG": "true"]) == false)
        #expect(CoverDropPerformanceLog.isEnabled(environment: ["COVERDROP_DEBUG_LOG": "1"]) == true)
    }

    @Test("性能日志字段顺序稳定并保留两位毫秒")
    func stableLineFormat() {
        let start = CoverDropPerformanceLog.startLine(
            operation: "打开详情",
            spanID: "span-1",
            thread: "main",
            context: ["albumID": "/Music/A", "albumCount": "5000"]
        )
        let end = CoverDropPerformanceLog.endLine(
            operation: "打开详情",
            spanID: "span-1",
            durationMilliseconds: 12.345,
            thread: "main",
            outcome: .success,
            context: ["albumID": "/Music/A"]
        )

        #expect(start == "[性能] 开始 operation=打开详情 span=span-1 thread=main albumCount=5000 albumID=/Music/A")
        #expect(end == "[性能] 结束 operation=打开详情 span=span-1 duration=12.35ms thread=main outcome=success albumID=/Music/A")
    }

    @Test("日志字段会清理换行和空白")
    func lineSanitizesWhitespace() {
        let line = CoverDropPerformanceLog.endLine(
            operation: "保存 封面",
            spanID: "span\n2",
            durationMilliseconds: 5,
            thread: "background",
            outcome: .failure,
            context: ["error": "第一行\n第二行"]
        )

        #expect(line.contains("operation=保存_封面"))
        #expect(line.contains("span=span_2"))
        #expect(line.contains("error=第一行_第二行"))
    }

    @Test("关闭日志时不求值上下文")
    func disabledLogDoesNotEvaluateContext() {
        let counter = EvaluationCounter()

        let span = CoverDropPerformanceLog.beginForTesting(
            "打开详情",
            enabled: false
        ) {
            counter.increment()
            return ["albumID": "A"]
        }

        #expect(span == nil)
        #expect(counter.value == 0)
    }

    @Test("慢成功操作和所有失败或取消操作都应上报")
    func reportingThresholdIncludesFailuresAndCancellations() {
        #expect(CoverDropPerformanceLog.shouldReport(
            durationMilliseconds: 99.99,
            outcome: .success,
            thresholdMilliseconds: 100
        ) == false)
        #expect(CoverDropPerformanceLog.shouldReport(
            durationMilliseconds: 100,
            outcome: .success,
            thresholdMilliseconds: 100
        ))
        #expect(CoverDropPerformanceLog.shouldReport(
            durationMilliseconds: 1,
            outcome: .failure,
            thresholdMilliseconds: 100
        ))
        #expect(CoverDropPerformanceLog.shouldReport(
            durationMilliseconds: 1,
            outcome: .cancelled,
            thresholdMilliseconds: 100
        ))
    }

    @Test("主线程响应探针直接投递到 AppKit 主队列")
    func mainThreadProbeRunsOnDispatchMainQueue() async {
        let ranOnMainThread = await CoverDropPerformanceLog.runMainQueueProbe {
            Thread.isMainThread
        }

        #expect(ranOnMainThread)
    }
}

private final class EvaluationCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var count = 0

    var value: Int {
        lock.withLock { count }
    }

    func increment() {
        lock.withLock {
            count += 1
        }
    }
}
