import XCTest
@testable import WHOOPHealthSyncCore

final class SyncResultTests: XCTestCase {
    func testPendingOrUncheckedPhasesRemainPartialWithoutGlobalErrors() {
        var summary = SyncSummary()
        XCTAssertTrue(summary.hasIncompleteResults)
        summary.sleepResult = .updated; summary.heartRateResult = .existing
        XCTAssertFalse(summary.hasIncompleteResults)
        summary.recovery.status = .readUnverified
        XCTAssertTrue(summary.hasIncompleteResults)
        summary.recovery.status = .completed; summary.recovery.pending = 1
        XCTAssertTrue(summary.hasIncompleteResults)
        summary.recovery.pending = 0; summary.recovery.deferredAccess = 1
        XCTAssertTrue(summary.hasIncompleteResults)
        summary.recovery.deferredAccess = 0
        XCTAssertFalse(summary.hasIncompleteResults)
        summary.heartRateResult = .pendingAccess
        XCTAssertTrue(summary.hasIncompleteResults)
        XCTAssertTrue(summary.errors.isEmpty)
    }

    func testEmptyWindowDoesNotReplaceConfirmedWritesOrAccessPending() {
        var accumulated = SyncSummary()
        accumulated.sleepResult = .updated; accumulated.stagesWritten = 3
        accumulated.heartRateResult = .pendingAccess
        var empty = SyncSummary(); empty.sleepResult = .noData; empty.heartRateResult = .noData
        accumulated.merge(empty)
        XCTAssertEqual(accumulated.sleepResult, .updated)
        XCTAssertEqual(accumulated.heartRateResult, .pendingAccess)
        XCTAssertEqual(accumulated.stagesWritten, 3)
    }

    func testLaterFailureMakesHistoryPartialWithoutErasingConfirmedSamples() {
        var summary = SyncSummary(); summary.sleepResult = .updated; summary.stagesWritten = 2
        var failure = SyncSummary(); failure.sleepResult = .failed; failure.errors = ["synthetic error"]
        summary.merge(failure)
        XCTAssertEqual(summary.sleepResult, .failed); XCTAssertEqual(summary.stagesWritten, 2)
        XCTAssertEqual(summary.errors.count, 1)
    }

    func testRecoverySettledStatusesAgreeWithIncompleteResults() {
        for status in [RecoveryFlowStatus.pausedNativeExport, .noData, .skippedExternal] {
            var recovery = RecoverySyncSummary(); recovery.status = status
            XCTAssertTrue(status.isSettled); XCTAssertTrue(recovery.isSettled)
            recovery.pending = 1
            XCTAssertFalse(recovery.isSettled)
        }
        XCTAssertFalse(RecoveryFlowStatus.historyPending.isSettled)
    }

    func testNoDataExistingAndUnverifiedAreDifferentResults() {
        XCTAssertNotEqual(SyncDataResult.noData, .existing)
        XCTAssertNotEqual(SyncDataResult.noData, .pendingAccess)
        XCTAssertNotEqual(SyncDataResult.notAttempted, .updated)
    }
}
