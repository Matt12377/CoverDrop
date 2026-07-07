import CoreServices
import Foundation

final class FSEventsLibraryChangeMonitor: LibraryChangeMonitoring, @unchecked Sendable {
    private let latency: TimeInterval
    private let queue = DispatchQueue(label: "com.yihe.CoverDrop.FSEvents", qos: .utility)

    init(latency: TimeInterval = 0.25) {
        self.latency = latency
    }

    func events(for rootURL: URL) -> AsyncThrowingStream<LibraryChangeEvent, Error> {
        let standardizedRootURL = rootURL.standardizedFileURL
        let rootPath = standardizedRootURL.path

        return AsyncThrowingStream { continuation in
            let state = FSEventsStreamState(
                rootURL: standardizedRootURL,
                continuation: continuation,
                queue: queue
            )
            let statePointer = Unmanaged.passRetained(state).toOpaque()
            var context = FSEventStreamContext(
                version: 0,
                info: statePointer,
                retain: nil,
                release: nil,
                copyDescription: nil
            )

            guard let stream = FSEventStreamCreate(
                kCFAllocatorDefault,
                libraryChangeEventCallback,
                &context,
                [rootPath] as CFArray,
                FSEventStreamEventId(kFSEventStreamEventIdSinceNow),
                latency,
                FSEventStreamCreateFlags(
                    kFSEventStreamCreateFlagUseCFTypes
                        | kFSEventStreamCreateFlagFileEvents
                        | kFSEventStreamCreateFlagNoDefer
                )
            ) else {
                Unmanaged<FSEventsStreamState>.fromOpaque(statePointer).release()
                continuation.finish(throwing: FSEventsLibraryChangeMonitorError.cannotCreateStream(rootPath))
                return
            }

            state.setStream(stream)
            FSEventStreamSetDispatchQueue(stream, queue)

            continuation.onTermination = { @Sendable _ in
                state.stop()
            }

            guard FSEventStreamStart(stream) else {
                state.stop()
                continuation.finish(throwing: FSEventsLibraryChangeMonitorError.cannotStartStream(rootPath))
                return
            }

            CoverDropDebugLog.write("实时刷新：FSEvents 监听已启动，根目录=\(rootPath)")
        }
    }
}

private final class FSEventsStreamState: @unchecked Sendable {
    let rootURL: URL
    let continuation: AsyncThrowingStream<LibraryChangeEvent, Error>.Continuation
    private let queue: DispatchQueue
    private let lock = NSLock()
    nonisolated(unsafe) private var _stream: FSEventStreamRef?
    nonisolated(unsafe) private var _isStopped = false

    init(
        rootURL: URL,
        continuation: AsyncThrowingStream<LibraryChangeEvent, Error>.Continuation,
        queue: DispatchQueue
    ) {
        self.rootURL = rootURL
        self.continuation = continuation
        self.queue = queue
    }

    nonisolated func setStream(_ stream: FSEventStreamRef) {
        lock.lock()
        _stream = stream
        lock.unlock()
    }

    nonisolated func stop() {
        lock.lock()
        guard !_isStopped else {
            lock.unlock()
            return
        }
        _isStopped = true
        guard let stream = _stream else {
            lock.unlock()
            return
        }
        _stream = nil
        lock.unlock()

        let sendableStream = SendableFSEventStream(stream)
        queue.async { [sendableStream] in
            CoverDropDebugLog.write("实时刷新：FSEvents 监听已停止")
            FSEventStreamStop(sendableStream.value)
            FSEventStreamInvalidate(sendableStream.value)
            FSEventStreamRelease(sendableStream.value)
            Unmanaged.passUnretained(self).release()
        }
    }

    nonisolated func yieldEvent(_ event: LibraryChangeEvent) {
        queue.async { [weak self] in
            guard let self else { return }
            self.continuation.yield(event)
        }
    }

    nonisolated func withStream<T>(_ body: (FSEventStreamRef?) -> T) -> T {
        lock.lock()
        let stream = _stream
        lock.unlock()
        return body(stream)
    }
}

private struct SendableFSEventStream: @unchecked Sendable {
    nonisolated(unsafe) let value: FSEventStreamRef

    nonisolated init(_ value: FSEventStreamRef) {
        self.value = value
    }
}

private let libraryChangeEventCallback: FSEventStreamCallback = {
    streamRef,
    clientCallBackInfo,
    numEvents,
    eventPaths,
    eventFlags,
    _ in
    guard let clientCallBackInfo else { return }

    let state = Unmanaged<FSEventsStreamState>
        .fromOpaque(clientCallBackInfo)
        .takeUnretainedValue()
    let rawPaths = unsafeBitCast(eventPaths, to: NSArray.self) as? [String] ?? []
    let rawFlags = (0..<numEvents).map { eventFlags[$0] }

    var filteredPaths: [String] = []
    var filteredFlags: [UInt32] = []
    for (index, path) in rawPaths.enumerated() {
        let fileName = (path as NSString).lastPathComponent
        if fileName.hasPrefix(".") {
            continue
        }
        filteredPaths.append(path)
        filteredFlags.append(rawFlags[index])
    }

    guard !filteredPaths.isEmpty else { return }

    let event = LibraryChangeEvent(
        rootURL: state.rootURL,
        changedPaths: filteredPaths,
        flags: filteredFlags
    )

    CoverDropDebugLog.write(
        "实时刷新：收到文件事件，根目录=\(state.rootURL.path)，原始事件数=\(numEvents)，过滤后=\(filteredPaths.count)，路径=\(filteredPaths.prefix(6).joined(separator: " | "))"
    )
    state.yieldEvent(event)
    _ = streamRef
}

enum FSEventsLibraryChangeMonitorError: LocalizedError, Sendable {
    case cannotCreateStream(String)
    case cannotStartStream(String)

    var errorDescription: String? {
        switch self {
        case .cannotCreateStream(let path):
            "无法创建目录变化监听：\(path)"
        case .cannotStartStream(let path):
            "无法启动目录变化监听：\(path)"
        }
    }
}
