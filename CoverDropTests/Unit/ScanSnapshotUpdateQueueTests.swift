import Foundation
import Testing
@testable import CoverDrop

struct ScanSnapshotUpdateQueueTests {
    @Test("同一音乐库写入期间保留每个待处理更新")
    func sameLibraryPreservesEveryPendingUpdate() async {
        let queue = ScanSnapshotUpdateQueue()
        let probe = SnapshotUpdateQueueProbe()
        let libraryID = UUID()

        await queue.submit(libraryID: libraryID) {
            await probe.recordAndBlockFirst(1)
        }
        await probe.waitUntilFirstStarted()

        await queue.submit(libraryID: libraryID) {
            await probe.record(2)
        }
        await queue.submit(libraryID: libraryID) {
            await probe.record(3)
        }

        await probe.releaseFirst()
        await queue.waitUntilIdle(for: libraryID)

        #expect(await probe.values == [1, 2, 3])
    }

    @Test("不同音乐库的快照更新可以独立推进")
    func differentLibrariesProgressIndependently() async {
        let queue = ScanSnapshotUpdateQueue()
        let probe = SnapshotUpdateQueueProbe()
        let firstLibraryID = UUID()
        let secondLibraryID = UUID()

        await queue.submit(libraryID: firstLibraryID) {
            await probe.recordAndBlockFirst(1)
        }
        await probe.waitUntilFirstStarted()
        await queue.submit(libraryID: secondLibraryID) {
            await probe.record(2)
        }
        await queue.waitUntilIdle(for: secondLibraryID)

        #expect(await probe.values.contains(2))
        await probe.releaseFirst()
        await queue.waitUntilIdle(for: firstLibraryID)
    }
}

private actor SnapshotUpdateQueueProbe {
    private(set) var values: [Int] = []
    private var firstContinuation: CheckedContinuation<Void, Never>?

    func recordAndBlockFirst(_ value: Int) async {
        values.append(value)
        await withCheckedContinuation { continuation in
            firstContinuation = continuation
        }
    }

    func record(_ value: Int) {
        values.append(value)
    }

    func waitUntilFirstStarted() async {
        while values.isEmpty {
            await Task.yield()
        }
    }

    func releaseFirst() {
        firstContinuation?.resume()
        firstContinuation = nil
    }
}
