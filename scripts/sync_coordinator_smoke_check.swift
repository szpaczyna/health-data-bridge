import Foundation
import WHOOPHealthSyncCore

@main
struct SyncCoordinatorSmokeCheck {
    @MainActor
    static func main() async throws {
        testLockRejectsSecondHolder()
        try await testConcurrentAutomationSharesOneRun()
        try await testFailedAutomationPostsOnceAndFreesLock()
        try await testAutomationWaitsForHeldLock()
        try await testAutomationGivesUpWhenLockIsNeverReleased()
        print("SyncCoordinator smoke check passed (lock, shared automation run, error post, wait-for-lock)")
    }

    @MainActor
    private static func testLockRejectsSecondHolder() {
        let coordinator = SyncCoordinator(notificationCenter: NotificationCenter(), pollIntervalNanoseconds: 1_000_000)
        expect(throwsSyncInProgress { try coordinator.acquire("a") } == false, "First acquire should succeed.")
        expect(coordinator.lockHolder == "a", "Lock holder should be the first operation.")
        expect(throwsSyncInProgress { try coordinator.acquire("b") }, "Second acquire should throw syncInProgress.")
        coordinator.release()
        expect(throwsSyncInProgress { try coordinator.acquire("b") } == false, "Acquire after release should succeed.")
        coordinator.release()
    }

    @MainActor
    private static func testConcurrentAutomationSharesOneRun() async throws {
        let center = NotificationCenter()
        let posts = PostCounter(center: center)
        let coordinator = SyncCoordinator(notificationCenter: center, pollIntervalNanoseconds: 1_000_000)
        let probe = WorkProbe()
        let work: @MainActor () async throws -> SyncSummary = {
            probe.runs += 1
            probe.lockHeldDuringWork = throwsSyncInProgress { try coordinator.acquire("other") }
            await waitUntil("Gate was never opened.") { probe.open }
            var summary = SyncSummary()
            summary.stagesWritten = 7
            return summary
        }

        let first = Task { @MainActor in try await coordinator.runAutomation(lockOperation: "automation", work) }
        let second = Task { @MainActor in try await coordinator.runAutomation(lockOperation: "automation", work) }
        await waitUntil("Work never started.") { probe.runs == 1 }
        probe.open = true
        let firstSummary = try await first.value
        let secondSummary = try await second.value

        expect(probe.runs == 1, "Concurrent automation calls should run the work once.")
        expect(firstSummary.stagesWritten == 7 && secondSummary == firstSummary, "Both callers should receive the shared summary.")
        expect(posts.count == 1, "Shared automation run should post exactly one notification.")
        expect(probe.lockHeldDuringWork, "Automation should hold the sync lock while the work runs.")
        expect(throwsSyncInProgress { try coordinator.acquire("after") } == false, "Lock should be free after automation.")
        coordinator.release()
    }

    @MainActor
    private static func testFailedAutomationPostsOnceAndFreesLock() async throws {
        let center = NotificationCenter()
        let posts = PostCounter(center: center)
        let coordinator = SyncCoordinator(notificationCenter: center, pollIntervalNanoseconds: 1_000_000)
        let probe = WorkProbe()
        let failing: @MainActor () async throws -> SyncSummary = {
            probe.runs += 1
            await waitUntil("Gate was never opened.") { probe.open }
            throw SmokeError.workFailed
        }

        let first = Task { @MainActor in try await coordinator.runAutomation(lockOperation: "automation", failing) }
        let second = Task { @MainActor in try await coordinator.runAutomation(lockOperation: "automation", failing) }
        await waitUntil("Work never started.") { probe.runs == 1 }
        probe.open = true
        let firstFailed = await throwsWorkFailed(first)
        let secondFailed = await throwsWorkFailed(second)
        expect(firstFailed, "Owner caller should rethrow the work error.")
        expect(secondFailed, "Joined caller should rethrow the work error.")
        expect(probe.runs == 1, "Failed automation should run the work once.")
        expect(posts.count == 1, "Failed automation should post exactly one notification.")
        expect(coordinator.lockHolder == nil, "Lock should be free after failed automation.")

        _ = try await coordinator.runAutomation(lockOperation: "automation") {
            probe.runs += 1
            return SyncSummary()
        }
        expect(probe.runs == 2, "A new automation run after a failure should run the work again.")
        expect(posts.count == 2, "The new automation run should post its own notification.")
    }

    @MainActor
    private static func testAutomationWaitsForHeldLock() async throws {
        let coordinator = SyncCoordinator(notificationCenter: NotificationCenter(), pollIntervalNanoseconds: 1_000_000, maxWaitAttempts: 1_000)
        let probe = WorkProbe()
        try coordinator.acquire("holder")
        let run = Task { @MainActor in
            try await coordinator.runAutomation(lockOperation: "automation") {
                probe.runs += 1
                return SyncSummary()
            }
        }
        await yieldTimes(10)
        expect(probe.runs == 0, "Automation must not start work while another operation holds the lock.")
        coordinator.release()
        _ = try await run.value
        expect(probe.runs == 1, "Automation should run once the lock is released.")
        expect(coordinator.lockHolder == nil, "Automation should release the lock it acquired.")
    }

    @MainActor
    private static func testAutomationGivesUpWhenLockIsNeverReleased() async throws {
        let center = NotificationCenter()
        let posts = PostCounter(center: center)
        let coordinator = SyncCoordinator(notificationCenter: center, pollIntervalNanoseconds: 1_000_000, maxWaitAttempts: 2)
        let probe = WorkProbe()
        try coordinator.acquire("holder")
        do {
            _ = try await coordinator.runAutomation(lockOperation: "automation") {
                probe.runs += 1
                return SyncSummary()
            }
            fatalError("Automation should give up while the lock stays held.")
        } catch LiveSyncRuntimeError.syncInProgress {}
        expect(probe.runs == 0, "Automation must not run work without the lock.")
        expect(posts.count == 1, "Automation should post the notification after giving up.")
        expect(coordinator.lockHolder == "holder", "Giving up must not release another operation's lock.")
        coordinator.release()
    }

    @MainActor
    private static func waitUntil(_ message: String, _ condition: () -> Bool) async {
        for _ in 0..<10_000 {
            if condition() { return }
            await Task.yield()
        }
        fatalError(message)
    }

    private static func yieldTimes(_ count: Int) async {
        for _ in 0..<count { await Task.yield() }
    }

    private static func throwsSyncInProgress(_ body: () throws -> Void) -> Bool {
        do { try body(); return false } catch LiveSyncRuntimeError.syncInProgress { return true } catch { fatalError("Unexpected error: \(error)") }
    }

    private static func throwsWorkFailed(_ task: Task<SyncSummary, Error>) async -> Bool {
        do { _ = try await task.value; return false } catch SmokeError.workFailed { return true } catch { fatalError("Unexpected error: \(error)") }
    }

    private static func expect(_ condition: @autoclosure () -> Bool, _ message: String) {
        guard condition() else {
            fatalError(message)
        }
    }
}

private enum SmokeError: Error {
    case workFailed
}

@MainActor
private final class WorkProbe {
    var runs = 0
    var open = false
    var lockHeldDuringWork = false
}

private final class PostCounter: @unchecked Sendable {
    private(set) var count = 0
    private var token: NSObjectProtocol?

    init(center: NotificationCenter) {
        token = center.addObserver(forName: .automationSyncFinished, object: nil, queue: nil) { [unowned self] _ in
            self.count += 1
        }
    }
}
