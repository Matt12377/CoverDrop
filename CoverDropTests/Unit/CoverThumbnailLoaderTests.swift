import Foundation
import Testing
@testable import CoverDrop

struct CoverThumbnailLoaderTests {
    @Test("不同缩略图请求受并发上限约束")
    func differentRequestsRespectConcurrencyLimit() async {
        let probe = ThumbnailDecoderProbe(isBlocked: false)
        let loader = CoverThumbnailLoader(maxConcurrentLoads: 4) { request in
            await probe.decode(request)
        }

        await withTaskGroup(of: Void.self) { group in
            for index in 0..<100 {
                group.addTask {
                    _ = await loader.image(for: Self.request(index))
                }
            }
        }

        #expect(await probe.callCount == 100)
        #expect(await probe.peakConcurrent <= 4)
    }

    @Test("同一缩略图请求由所有消费者共享一次解码")
    func identicalRequestsShareOneDecode() async {
        let probe = ThumbnailDecoderProbe(isBlocked: true)
        let loader = CoverThumbnailLoader(maxConcurrentLoads: 4) { request in
            await probe.decode(request)
        }

        let tasks = (0..<20).map { _ in
            Task { await loader.image(for: Self.request(1)) }
        }
        await waitUntil { await probe.callCount == 1 }
        await probe.release()
        for task in tasks {
            _ = await task.value
        }

        #expect(await probe.callCount == 1)
    }

    @Test("排队请求取消后不会启动解码")
    func cancelledQueuedRequestNeverDecodes() async {
        let probe = ThumbnailDecoderProbe(isBlocked: true)
        let loader = CoverThumbnailLoader(maxConcurrentLoads: 4) { request in
            await probe.decode(request)
        }
        let running = (0..<4).map { index in
            Task { await loader.image(for: Self.request(index)) }
        }
        await waitUntil { await probe.activeCount == 4 }

        let cancelled = Task { await loader.image(for: Self.request(99)) }
        cancelled.cancel()
        _ = await cancelled.value
        await probe.release()
        for task in running {
            _ = await task.value
        }

        #expect(!(await probe.requestIndexes).contains(99))
    }

    private static func request(_ index: Int) -> CoverThumbnailLoader.Request {
        CoverThumbnailLoader.Request(
            url: URL(fileURLWithPath: "/tmp/CoverDrop/\(index).jpg"),
            maxPixelSize: 336,
            contentRevision: UInt64(index)
        )
    }
}

private actor ThumbnailDecoderProbe {
    private var blocked: Bool
    private var continuations: [CheckedContinuation<Void, Never>] = []
    private(set) var callCount = 0
    private(set) var activeCount = 0
    private(set) var peakConcurrent = 0
    private(set) var requestIndexes: [Int] = []

    init(isBlocked: Bool) {
        blocked = isBlocked
    }

    func decode(_ request: CoverThumbnailLoader.Request) async -> SendableNSImage? {
        callCount += 1
        activeCount += 1
        peakConcurrent = max(peakConcurrent, activeCount)
        requestIndexes.append(Int(request.contentRevision))
        if blocked {
            await withCheckedContinuation { continuation in
                continuations.append(continuation)
            }
        } else {
            try? await Task.sleep(for: .milliseconds(2))
        }
        activeCount -= 1
        return nil
    }

    func release() {
        blocked = false
        let pending = continuations
        continuations.removeAll()
        for continuation in pending {
            continuation.resume()
        }
    }
}

private func waitUntil(
    timeout: Duration = .seconds(2),
    condition: @escaping @Sendable () async -> Bool
) async {
    let clock = ContinuousClock()
    let deadline = clock.now.advanced(by: timeout)
    while clock.now < deadline {
        if await condition() {
            return
        }
        try? await Task.sleep(for: .milliseconds(5))
    }
}
