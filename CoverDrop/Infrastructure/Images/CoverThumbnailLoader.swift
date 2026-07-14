import AppKit
import Foundation

struct SendableNSImage: @unchecked Sendable {
    let image: NSImage
}

actor CoverThumbnailLoader {
    struct Request: Hashable, Sendable {
        let url: URL
        let maxPixelSize: Int
        let contentRevision: UInt64

        init(url: URL, maxPixelSize: CGFloat, contentRevision: UInt64) {
            self.url = url.standardizedFileURL
            self.maxPixelSize = Int(maxPixelSize.rounded(.up))
            self.contentRevision = contentRevision
        }
    }

    typealias Decoder = @Sendable (Request) async -> SendableNSImage?

    nonisolated static let shared = CoverThumbnailLoader(
        maxConcurrentLoads: AppConfiguration.CoverImages.defaultConcurrentLocalThumbnails
    ) { request in
        CoverPreviewCache.cachedImage(
            for: request.url,
            maxPixelSize: CGFloat(request.maxPixelSize),
            contentRevision: request.contentRevision
        ).map(SendableNSImage.init(image:))
    }

    private struct Job {
        let request: Request
        var consumers: [UUID: CheckedContinuation<SendableNSImage?, Never>]
        var isRunning: Bool
    }

    private let maxConcurrentLoads: Int
    private let decoder: Decoder
    private var jobs: [Request: Job] = [:]
    private var queue: [Request] = []
    private var queueHead = 0
    private var runningCount = 0
    private var cancelledConsumerIDs: Set<UUID> = []

    init(maxConcurrentLoads: Int, decoder: @escaping Decoder) {
        self.maxConcurrentLoads = max(1, maxConcurrentLoads)
        self.decoder = decoder
    }

    func image(for request: Request) async -> SendableNSImage? {
        let consumerID = UUID()
        return await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                register(
                    consumerID: consumerID,
                    request: request,
                    continuation: continuation
                )
            }
        } onCancel: {
            Task {
                await self.cancel(consumerID: consumerID, request: request)
            }
        }
    }

    private func register(
        consumerID: UUID,
        request: Request,
        continuation: CheckedContinuation<SendableNSImage?, Never>
    ) {
        if cancelledConsumerIDs.remove(consumerID) != nil {
            continuation.resume(returning: nil)
            return
        }

        if var job = jobs[request] {
            job.consumers[consumerID] = continuation
            jobs[request] = job
        } else {
            jobs[request] = Job(
                request: request,
                consumers: [consumerID: continuation],
                isRunning: false
            )
            queue.append(request)
        }
        startQueuedJobsIfPossible()
    }

    private func cancel(consumerID: UUID, request: Request) {
        guard var job = jobs[request] else {
            cancelledConsumerIDs.insert(consumerID)
            return
        }
        guard let continuation = job.consumers.removeValue(forKey: consumerID) else {
            return
        }
        continuation.resume(returning: nil)
        if job.consumers.isEmpty, !job.isRunning {
            jobs[request] = nil
        } else {
            jobs[request] = job
        }
        startQueuedJobsIfPossible()
    }

    private func startQueuedJobsIfPossible() {
        while runningCount < maxConcurrentLoads, queueHead < queue.count {
            let request = queue[queueHead]
            queueHead += 1
            guard var job = jobs[request],
                  !job.isRunning,
                  !job.consumers.isEmpty else {
                continue
            }
            job.isRunning = true
            jobs[request] = job
            runningCount += 1

            let decoder = decoder
            Task.detached(priority: .utility) { [weak self] in
                let result = await decoder(request)
                await self?.complete(request: request, result: result)
            }
        }

        if queueHead > 1_024, queueHead * 2 > queue.count {
            queue.removeFirst(queueHead)
            queueHead = 0
        }
    }

    private func complete(request: Request, result: SendableNSImage?) {
        guard let job = jobs.removeValue(forKey: request), job.isRunning else {
            return
        }
        runningCount -= 1
        for continuation in job.consumers.values {
            continuation.resume(returning: result)
        }
        startQueuedJobsIfPossible()
    }
}
