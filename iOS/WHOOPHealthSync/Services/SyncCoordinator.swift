import Foundation
import WHOOPHealthSyncCore

@MainActor
final class SyncCoordinator {
    private(set) var lockHolder: String?
    private var automationTask: Task<SyncSummary, Error>?
    private let notificationCenter: NotificationCenter
    private let pollIntervalNanoseconds: UInt64
    private let maxWaitAttempts: Int

    init(notificationCenter: NotificationCenter = .default, pollIntervalNanoseconds: UInt64 = 500_000_000, maxWaitAttempts: Int = 50) {
        self.notificationCenter = notificationCenter
        self.pollIntervalNanoseconds = pollIntervalNanoseconds
        self.maxWaitAttempts = maxWaitAttempts
    }

    func acquire(_ operation: String) throws {
        if let lockHolder {
            AppLog.sync.warning("Rejected \(operation, privacy: .public): \(lockHolder, privacy: .public) holds the sync lock.")
            throw LiveSyncRuntimeError.syncInProgress
        }
        lockHolder = operation
    }

    func release() {
        lockHolder = nil
    }

    // A background launch for the intent can coincide with another operation that releases the lock shortly after.
    func waitForLock() async throws {
        var attempts = 0
        while let holder = lockHolder, attempts < maxWaitAttempts {
            if attempts == 0 { AppLog.sync.info("Automation waiting for \(holder, privacy: .public) to release the sync lock.") }
            attempts += 1
            try await Task.sleep(nanoseconds: pollIntervalNanoseconds)
        }
    }

    func runAutomation(lockOperation: String, _ work: @escaping @MainActor () async throws -> SyncSummary) async throws -> SyncSummary {
        // Shortcuts can start the intent twice at once; the second caller shares the first run.
        if let automationTask {
            AppLog.sync.info("Automation joined the sync already started by Shortcuts.")
            return try await automationTask.value
        }
        let task = Task { @MainActor in
            try await self.waitForLock()
            try self.acquire(lockOperation); defer { self.release() }
            return try await work()
        }
        automationTask = task
        defer {
            automationTask = nil
            notificationCenter.post(name: .automationSyncFinished, object: nil)
        }
        return try await task.value
    }
}

extension Notification.Name {
    static let automationSyncFinished = Notification.Name("org.shpaq.WHOOPHealthSync.automationSyncFinished")
}

enum LiveSyncRuntimeError: Error, LocalizedError {
    case syncInProgress

    var errorDescription: String? {
        String(localized: "Another HealthDataBridge sync is still running. Try again when it finishes.")
    }
}
