import Foundation

struct LibraryChangeEvent: Equatable, Sendable {
    let rootURL: URL
    let changedPaths: [String]
    let flags: [UInt32]

    nonisolated init(rootURL: URL, changedPaths: [String], flags: [UInt32] = []) {
        self.rootURL = rootURL
        self.changedPaths = changedPaths
        self.flags = flags
    }
}

protocol LibraryChangeMonitoring: Sendable {
    func events(for rootURL: URL) -> AsyncThrowingStream<LibraryChangeEvent, Error>
}

struct DisabledLibraryChangeMonitor: LibraryChangeMonitoring {
    func events(for rootURL: URL) -> AsyncThrowingStream<LibraryChangeEvent, Error> {
        AsyncThrowingStream { continuation in
            continuation.finish()
        }
    }
}
