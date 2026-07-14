import Foundation
import Testing
@testable import CoverDrop

struct RemoteCoverImageDataCacheTests {
    @Test("重复请求同一 URL 时复用已缓存图片数据")
    func reusesCachedDataForSameURL() async throws {
        let cache = RemoteCoverImageDataCache()
        let counter = DataLoaderCounter()
        let url = try #require(URL(string: "https://example.com/cover.jpg"))

        let first = try await cache.value(for: url) {
            await counter.load(Data([1, 2, 3]))
        }
        let second = try await cache.value(for: url) {
            await counter.load(Data([4, 5, 6]))
        }

        #expect(first == Data([1, 2, 3]))
        #expect(second == Data([1, 2, 3]))
        #expect(await counter.count == 1)
    }

    @Test("并发请求同一 URL 时合并进行中的加载任务")
    func sharesInFlightLoadForSameURL() async throws {
        let cache = RemoteCoverImageDataCache()
        let counter = DataLoaderCounter()
        let url = try #require(URL(string: "https://example.com/cover.jpg"))

        async let first = cache.value(for: url) {
            await counter.load(Data([1, 2, 3]), delayNanoseconds: 50_000_000)
        }
        async let second = cache.value(for: url) {
            await counter.load(Data([1, 2, 3]), delayNanoseconds: 50_000_000)
        }

        #expect(try await first == Data([1, 2, 3]))
        #expect(try await second == Data([1, 2, 3]))
        #expect(await counter.count == 1)
    }

    @Test("缓存超过有效期后重新加载图片数据")
    func reloadsExpiredData() async throws {
        let clock = TestDateSource(now: Date(timeIntervalSince1970: 0))
        let cache = RemoteCoverImageDataCache(
            timeToLive: 60,
            now: { clock.now }
        )
        let counter = DataLoaderCounter()
        let url = try #require(URL(string: "https://example.com/cover.jpg"))

        _ = try await cache.value(for: url) {
            await counter.load(Data([1]))
        }
        clock.advance(by: 61)
        let reloaded = try await cache.value(for: url) {
            await counter.load(Data([2]))
        }

        #expect(reloaded == Data([2]))
        #expect(await counter.count == 2)
    }

    @Test("加载失败不会写入远程图片缓存")
    func failuresAreNotCached() async throws {
        enum SampleFailure: Error { case failed }
        let cache = RemoteCoverImageDataCache()
        let url = try #require(URL(string: "https://example.com/failure.jpg"))

        await #expect(throws: SampleFailure.self) {
            _ = try await cache.value(for: url) {
                throw SampleFailure.failed
            }
        }
        let data = try await cache.value(for: url) { Data([9]) }

        #expect(data == Data([9]))
    }

    @Test("超过项目上限时淘汰最早远程图片")
    func evictsOldestEntryOverCountLimit() async throws {
        let clock = TestDateSource(now: Date(timeIntervalSince1970: 0))
        let cache = RemoteCoverImageDataCache(
            maximumEntryCount: 1,
            now: { clock.now }
        )
        let counter = DataLoaderCounter()
        let firstURL = try #require(URL(string: "https://example.com/first.jpg"))
        let secondURL = try #require(URL(string: "https://example.com/second.jpg"))

        _ = try await cache.value(for: firstURL) { await counter.load(Data([1])) }
        clock.advance(by: 1)
        _ = try await cache.value(for: secondURL) { await counter.load(Data([2])) }
        _ = try await cache.value(for: firstURL) { await counter.load(Data([3])) }

        #expect(await counter.count == 3)
    }

    @Test("不同远程图片请求受并发上限约束")
    func differentURLsRespectConcurrencyLimit() async throws {
        let cache = RemoteCoverImageDataCache(maximumConcurrentLoads: 6)
        let probe = RemoteDataConcurrencyProbe()

        try await withThrowingTaskGroup(of: Void.self) { group in
            for index in 0..<20 {
                group.addTask {
                    let url = URL(string: "https://example.com/\(index).jpg")!
                    _ = try await cache.value(for: url) {
                        await probe.load()
                    }
                }
            }
            try await group.waitForAll()
        }

        #expect(await probe.peakConcurrent <= 6)
        #expect(await probe.callCount == 20)
    }

    @Test("排队中的最后一个消费者取消后不会启动远程加载")
    func cancelledQueuedLoadNeverStarts() async throws {
        let cache = RemoteCoverImageDataCache(maximumConcurrentLoads: 1)
        let probe = BlockingRemoteLoadProbe()
        let firstURL = try #require(URL(string: "https://example.com/first.jpg"))
        let secondURL = try #require(URL(string: "https://example.com/second.jpg"))

        let first = Task {
            try? await cache.value(for: firstURL) {
                try await probe.load(1)
            }
        }
        await probe.waitUntilStartedCount(1)
        let second = Task {
            try? await cache.value(for: secondURL) {
                try await probe.load(2)
            }
        }
        try? await Task.sleep(for: .milliseconds(20))
        second.cancel()

        await probe.releaseAll()
        _ = await first.value
        _ = await second.value

        #expect(await probe.startedValues == [1])
    }
}

private actor BlockingRemoteLoadProbe {
    private(set) var startedValues: [Int] = []
    private var continuations: [CheckedContinuation<Void, Never>] = []

    func load(_ value: Int) async throws -> Data {
        startedValues.append(value)
        if value == 1 {
            await withCheckedContinuation { continuation in
                continuations.append(continuation)
            }
        }
        try Task.checkCancellation()
        return Data([UInt8(value)])
    }

    func waitUntilStartedCount(_ expectedCount: Int) async {
        while startedValues.count < expectedCount {
            await Task.yield()
        }
    }

    func releaseAll() {
        let pending = continuations
        continuations.removeAll()
        for continuation in pending {
            continuation.resume()
        }
    }
}

private actor RemoteDataConcurrencyProbe {
    private(set) var callCount = 0
    private(set) var peakConcurrent = 0
    private var currentConcurrent = 0

    func load() async -> Data {
        callCount += 1
        currentConcurrent += 1
        peakConcurrent = max(peakConcurrent, currentConcurrent)
        try? await Task.sleep(for: .milliseconds(10))
        currentConcurrent -= 1
        return Data([1])
    }
}

private actor DataLoaderCounter {
    private(set) var count = 0

    func load(_ data: Data, delayNanoseconds: UInt64 = 0) async -> Data {
        count += 1
        if delayNanoseconds > 0 {
            try? await Task.sleep(nanoseconds: delayNanoseconds)
        }
        return data
    }
}

private final class TestDateSource: @unchecked Sendable {
    private nonisolated let lock = NSLock()
    private nonisolated(unsafe) var value: Date

    init(now: Date) {
        value = now
    }

    nonisolated var now: Date {
        lock.withLock { value }
    }

    nonisolated func advance(by interval: TimeInterval) {
        lock.withLock {
            value = value.addingTimeInterval(interval)
        }
    }
}
