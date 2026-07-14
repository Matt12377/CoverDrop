import Foundation

actor RemoteCoverImageDataCache {
    typealias Loader = @Sendable () async throws -> Data

    private struct Entry {
        let data: Data
        let cachedAt: Date
    }

    private struct Job {
        let id: UUID
        let url: URL
        let loader: Loader
        var consumers: [UUID: CheckedContinuation<Data, any Error>]
        var task: Task<Data, any Error>?
        var acceptsConsumers: Bool
    }

    private let maximumEntryCount: Int
    private let maximumByteCount: Int
    private let timeToLive: TimeInterval
    private let maximumConcurrentLoads: Int
    private let now: @Sendable () -> Date

    private var entries: [URL: Entry] = [:]
    private var jobsByID: [UUID: Job] = [:]
    private var currentJobIDByURL: [URL: UUID] = [:]
    private var jobIDByConsumerID: [UUID: UUID] = [:]
    private var queuedJobIDs: [UUID] = []
    private var queueHead = 0
    private var runningCount = 0

    init(
        maximumEntryCount: Int = 20,
        maximumByteCount: Int = 64 * 1024 * 1024,
        timeToLive: TimeInterval = 60,
        maximumConcurrentLoads: Int = AppConfiguration.CoverImages.defaultConcurrentRemotePreviews,
        now: @escaping @Sendable () -> Date = { .now }
    ) {
        self.maximumEntryCount = maximumEntryCount
        self.maximumByteCount = maximumByteCount
        self.timeToLive = timeToLive
        self.maximumConcurrentLoads = max(1, maximumConcurrentLoads)
        self.now = now
    }

    func value(for url: URL, load: @escaping Loader) async throws -> Data {
        let currentDate = now()
        if let entry = entries[url] {
            if currentDate.timeIntervalSince(entry.cachedAt) <= timeToLive {
                return entry.data
            }
            entries[url] = nil
        }

        let consumerID = UUID()
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                register(
                    consumerID: consumerID,
                    url: url,
                    load: load,
                    continuation: continuation
                )
            }
        } onCancel: {
            Task {
                await self.cancel(consumerID: consumerID)
            }
        }
    }

    private func register(
        consumerID: UUID,
        url: URL,
        load: @escaping Loader,
        continuation: CheckedContinuation<Data, any Error>
    ) {
        if let jobID = currentJobIDByURL[url],
           var job = jobsByID[jobID],
           job.acceptsConsumers {
            job.consumers[consumerID] = continuation
            jobsByID[jobID] = job
            jobIDByConsumerID[consumerID] = jobID
            return
        }

        let jobID = UUID()
        jobsByID[jobID] = Job(
            id: jobID,
            url: url,
            loader: load,
            consumers: [consumerID: continuation],
            task: nil,
            acceptsConsumers: true
        )
        currentJobIDByURL[url] = jobID
        jobIDByConsumerID[consumerID] = jobID
        queuedJobIDs.append(jobID)
        startQueuedJobsIfPossible()
    }

    private func cancel(consumerID: UUID) {
        guard let jobID = jobIDByConsumerID.removeValue(forKey: consumerID),
              var job = jobsByID[jobID],
              let continuation = job.consumers.removeValue(forKey: consumerID) else {
            return
        }

        continuation.resume(throwing: CancellationError())
        guard job.consumers.isEmpty else {
            jobsByID[jobID] = job
            return
        }

        job.acceptsConsumers = false
        if currentJobIDByURL[job.url] == jobID {
            currentJobIDByURL[job.url] = nil
        }

        if let task = job.task {
            task.cancel()
            jobsByID[jobID] = job
        } else {
            jobsByID[jobID] = nil
        }
        startQueuedJobsIfPossible()
    }

    private func startQueuedJobsIfPossible() {
        while runningCount < maximumConcurrentLoads, queueHead < queuedJobIDs.count {
            let jobID = queuedJobIDs[queueHead]
            queueHead += 1
            guard var job = jobsByID[jobID],
                  job.task == nil,
                  job.acceptsConsumers,
                  !job.consumers.isEmpty else {
                continue
            }

            let loader = job.loader
            let task = Task.detached(priority: .utility) {
                try await loader()
            }
            job.task = task
            jobsByID[jobID] = job
            runningCount += 1

            Task.detached { [weak self] in
                let result = await task.result
                await self?.complete(jobID: jobID, result: result)
            }
        }

        if queueHead > 1_024, queueHead * 2 > queuedJobIDs.count {
            queuedJobIDs.removeFirst(queueHead)
            queueHead = 0
        }
    }

    private func complete(
        jobID: UUID,
        result: Result<Data, any Error>
    ) {
        guard let job = jobsByID.removeValue(forKey: jobID), job.task != nil else {
            return
        }
        runningCount -= 1

        let isCurrentJob = currentJobIDByURL[job.url] == jobID
        if isCurrentJob {
            currentJobIDByURL[job.url] = nil
        }
        for consumerID in job.consumers.keys {
            jobIDByConsumerID[consumerID] = nil
        }

        switch result {
        case .success(let data):
            if isCurrentJob, job.acceptsConsumers {
                store(data, for: job.url, at: now())
            }
            for continuation in job.consumers.values {
                continuation.resume(returning: data)
            }
        case .failure(let error):
            for continuation in job.consumers.values {
                continuation.resume(throwing: error)
            }
        }

        startQueuedJobsIfPossible()
    }

    private func store(_ data: Data, for url: URL, at date: Date) {
        entries[url] = Entry(data: data, cachedAt: date)

        while entries.count > maximumEntryCount || totalByteCount > maximumByteCount {
            guard let oldestURL = entries.min(by: { $0.value.cachedAt < $1.value.cachedAt })?.key else {
                return
            }
            entries[oldestURL] = nil
        }
    }

    private var totalByteCount: Int {
        entries.values.reduce(into: 0) { total, entry in
            total += entry.data.count
        }
    }
}
