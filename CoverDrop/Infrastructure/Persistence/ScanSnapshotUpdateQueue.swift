import Foundation

actor ScanSnapshotUpdateQueue {
    typealias Operation = @Sendable () async -> Void

    private var runningLibraryIDs: Set<LibraryRecord.ID> = []
    private var pendingOperationsByLibraryID: [LibraryRecord.ID: [Operation]] = [:]
    private var idleWaitersByLibraryID: [
        LibraryRecord.ID: [CheckedContinuation<Void, Never>]
    ] = [:]

    func submit(
        libraryID: LibraryRecord.ID,
        operation: @escaping Operation
    ) {
        guard !runningLibraryIDs.contains(libraryID) else {
            pendingOperationsByLibraryID[libraryID, default: []].append(operation)
            return
        }

        runningLibraryIDs.insert(libraryID)
        Task {
            await drain(libraryID: libraryID, firstOperation: operation)
        }
    }

    func waitUntilIdle(for libraryID: LibraryRecord.ID) async {
        guard runningLibraryIDs.contains(libraryID) else { return }
        await withCheckedContinuation { continuation in
            idleWaitersByLibraryID[libraryID, default: []].append(continuation)
        }
    }

    private func drain(
        libraryID: LibraryRecord.ID,
        firstOperation: @escaping Operation
    ) async {
        var nextOperation: Operation? = firstOperation
        while let operation = nextOperation {
            await operation()
            nextOperation = dequeuePendingOperation(for: libraryID)
        }

        runningLibraryIDs.remove(libraryID)
        let waiters = idleWaitersByLibraryID.removeValue(forKey: libraryID) ?? []
        waiters.forEach { $0.resume() }
    }

    private func dequeuePendingOperation(for libraryID: LibraryRecord.ID) -> Operation? {
        guard var pendingOperations = pendingOperationsByLibraryID[libraryID],
              !pendingOperations.isEmpty else {
            pendingOperationsByLibraryID[libraryID] = nil
            return nil
        }

        let operation = pendingOperations.removeFirst()
        pendingOperationsByLibraryID[libraryID] = pendingOperations.isEmpty ? nil : pendingOperations
        return operation
    }
}
