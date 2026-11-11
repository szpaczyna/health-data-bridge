import Foundation
import WHOOPHealthSyncCore
#if os(iOS)
import UIKit
#endif

@MainActor
final class LiveSyncRuntime {
    static let shared = LiveSyncRuntime()

    let authService: WhoopAuthService
    let repository: SyncRepository
    let preferredHeartRateStepSeconds: Int

    private let api: WhoopAPIClient
    private let healthKitService: HealthKitService
    private var syncLockHolder: String?
    private var automationTask: Task<SyncSummary, Error>?
    private let recoveryAdapter: HealthKitRecoveryAdapter
    private let recoveryPipeline: RecoverySyncPipeline
    private let syncEngine: SyncEngine
    private var operationSummary: SyncSummary?
    var historyProgressChanged: (() -> Void)?

    private init() {
        let tokenStore = KeychainTokenStore()
        let authService = WhoopAuthService(tokenStore: tokenStore)
        let apiConfiguration = WhoopPrivateAPIConfiguration()
        let api = WhoopAPIClient(auth: authService, configuration: apiConfiguration)
        let healthKitService = HealthKitService()
        let repository = SyncRepository()

        self.api = api
        self.authService = authService
        self.healthKitService = healthKitService
        self.repository = repository
        self.preferredHeartRateStepSeconds = apiConfiguration.preferredHeartRateStepSeconds
        let recoveryAdapter = HealthKitRecoveryAdapter(manualConfirmation: { (try? repository.recoveryState().userConfirmedFullReadAccess) == true }, officialBundle: { try? repository.recoveryState().officialWhoopBundle })
        self.recoveryAdapter = recoveryAdapter
        let provider = WhoopPrivateRecoveryProvider(currentUserID: { try await api.fetchCurrentUser().id }, fetch: { id, window in
            try await api.fetchRecoveryCycleRecords(userID: id, window: window)
        }, state: { try repository.recoveryState() }, commitState: { try repository.commitRecoveryState($0) })
        let recoveryPipeline = RecoverySyncPipeline(provider: provider, health: recoveryAdapter, persistence: repository, appBundle: Bundle.main.bundleIdentifier ?? "com.joselourido.WHOOPHealthSync", canContinueHistory: {
            #if os(iOS)
            return UIApplication.shared.applicationState == .active
            #else
            return true
            #endif
        }, canContinueSync: {
            if case .authenticated = authService.currentStatus() { return true }; return false
        })
        self.recoveryPipeline = recoveryPipeline
        self.syncEngine = SyncEngine(
            api: api,
            healthKit: healthKitService,
            repository: repository,
            heartRateStepSeconds: apiConfiguration.preferredHeartRateStepSeconds,
            requiresInitialHealthKitReadVisibility: true,
            recoveryPipeline: recoveryPipeline
        )
    }

    var recoveryProgressChanged: ((RecoverySyncState, RecoverySyncSummary) -> Void)? {
        get { recoveryPipeline.progressChanged }
        set { recoveryPipeline.progressChanged = newValue }
    }
    var recoveryAvailable: Bool { recoveryAdapter.supported }
    func authorizeRecovery() async throws -> RecoveryAuthorization {
        try acquireSyncLock(); defer { releaseSyncLock() }
        try await recoveryAdapter.requestAuthorization()
        return try await inspectRecoveryAuthorization()
    }

    // Inspect with a fresh confirmation. Opening/cancelling setup must not alter saved HRV state.
    private func inspectRecoveryAuthorization() async throws -> RecoveryAuthorization {
        let writeAuthorized = (try? recoveryAdapter.validateWriteAuthorization()) != nil
        let inspection = HealthKitRecoveryAdapter(officialBundle: { try? self.repository.recoveryState().officialWhoopBundle })
        let access = try await inspection.readAccess()
        let sources = try await inspection.observedWhoopSources()
        return RecoveryAuthorization(sources: sources, access: access, writeAuthorized: writeAuthorized)
    }

    func authorizeSyncData(includeRecovery: Bool) async throws -> RecoveryAuthorization? {
        try await authorizeSelectedData(includeRecovery: includeRecovery).recovery
    }

    func authorizeSelectedData(includeRecovery: Bool) async throws -> SyncDataAuthorization {
        try acquireSyncLock(); defer { releaseSyncLock() }
        try repository.ensureUsable()
        var result = try await healthKitService.requestSelectedAuthorization(includeRecovery: includeRecovery && recoveryAvailable)
        result.recovery = includeRecovery && recoveryAvailable ? try await inspectRecoveryAuthorization() : nil
        return result
    }

    func saveSyncSetup(includeRecovery: Bool, fullReadConfirmed: Bool, whoopBundle: String?, now: Date) async throws {
        try acquireSyncLock(); defer { releaseSyncLock() }
        try repository.ensureUsable()
        guard !repository.requiresManualAccountBinding else { throw SyncRepositoryError.accountBindingRequired }
        guard case let .authenticated(email) = authService.currentStatus() else { throw AutomatedSyncError.whoopNotConnected }
        let key = WhoopRecovery.pseudonymousAccountKey(userID: try await api.fetchCurrentUser().id)
        try healthKitService.validateExistingAuthorization()
        var state = try repository.recoveryState()
        if includeRecovery {
            guard HKRecoverySetup.validBundle(whoopBundle) else { throw RecoverySyncError.invalidRecord }
            let adapter = HealthKitRecoveryAdapter(manualConfirmation: { fullReadConfirmed }, officialBundle: { whoopBundle })
            let sources = try await adapter.observedWhoopSources()
            if let whoopBundle {
                guard sources.contains(where: { $0.bundle == whoopBundle }) else { throw RecoverySyncError.readUnverified }
            }
            try adapter.validateWriteAuthorization()
            let access = try await adapter.readAccess()
            guard access != .unknown else { throw RecoverySyncError.readUnverified }
            state.accountKey = key
            if state.historyStartDate == nil { state.historyScopeLimited = true }
            state.historyStartDate = state.historyStartDate ?? now.addingTimeInterval(-7 * 86400)
            state.userConfirmedFullReadAccess = fullReadConfirmed
            state.officialWhoopBundle = whoopBundle
            state.enabled = true; state.configured = true
            state.pausedForNativeExport = false
            if case let .nativeExporter(bundle) = access {
                state.officialWhoopBundle = bundle; state.pausedForNativeExport = true
            }
        } else { state.enabled = false }
        try Task.checkCancellation()
        guard case let .authenticated(current) = authService.currentStatus(), current == email else { throw RecoverySyncError.accountMismatch }
        try repository.saveSyncSetup(recovery: state, accountKey: key)
    }
    func configureRecovery(start: Date, fullReadConfirmed: Bool, whoopBundle: String?) async throws {
        try acquireSyncLock(); defer { releaseSyncLock() }
        guard case let .authenticated(email) = authService.currentStatus() else { throw AutomatedSyncError.whoopNotConnected }
        let user = try await api.fetchCurrentUser()
        let key = WhoopRecovery.pseudonymousAccountKey(userID: user.id)
        try repository.validateAccount(key)
        guard case let .authenticated(current) = authService.currentStatus(), current == email else { throw RecoverySyncError.accountMismatch }
        guard start < Date(), HKRecoverySetup.validBundle(whoopBundle) else { throw RecoverySyncError.invalidRecord }
        let setupAdapter = HealthKitRecoveryAdapter(manualConfirmation: { fullReadConfirmed }, officialBundle: { whoopBundle })
        try setupAdapter.validateWriteAuthorization()
        let access = try await setupAdapter.readAccess()
        guard access != .unknown else { throw RecoverySyncError.readUnverified }
        guard case let .authenticated(afterAuthorization) = authService.currentStatus(), afterAuthorization == email else { throw RecoverySyncError.accountMismatch }
        var state = try repository.recoveryState()
        if state.historyStartDate != start {
            state.historicalCursor = nil; state.initialEnumerationComplete = false; state.historicalPagesConfirmed = 0
            state.confirmedCursorFingerprints = []; state.initialImportCutoff = nil
        }
        state.accountKey = key; state.historyStartDate = start
        state.userConfirmedFullReadAccess = fullReadConfirmed; state.officialWhoopBundle = whoopBundle
        state.historyScopeLimited = true; state.pausedForNativeExport = false
        state.enabled = true; state.configured = true
        try repository.commitRecoveryState(state)
        if case let .nativeExporter(bundle) = access {
            state.officialWhoopBundle = bundle; state.pausedForNativeExport = true
            try repository.commitRecoveryState(state)
        }
    }

    func requestHealthKitAuthorization() async throws {
        try await healthKitService.requestAuthorization()
    }

    func synchronize() async throws -> SyncSummary {
        try acquireSyncLock(); defer { releaseSyncLock() }
        operationSummary = nil
        try repository.ensureUsable()
        guard repository.hasCompletedSyncSetup else { throw AutomatedSyncError.initialManualSyncRequired }
        try healthKitService.validateExistingAuthorization()
        do {
            // Keep legacy manual access-pending reconciliation. Explicit history has separate cursors.
            let summary = try await syncEngine.synchronize(recoveryMode: .recent, resumeDeferred: true)
            operationSummary = summary; return summary
        } catch { operationSummary = syncEngine.lastSummary; throw error }
    }

    var latestOperationSummary: SyncSummary? { operationSummary }

    func importHistory(start: Date?) async throws -> SyncSummary {
        try acquireSyncLock(); defer { releaseSyncLock() }
        operationSummary = nil
        try repository.ensureUsable()
        guard case let .authenticated(email) = authService.currentStatus() else { throw AutomatedSyncError.whoopNotConnected }
        let user = try await api.fetchCurrentUser()
        guard case let .authenticated(current) = authService.currentStatus(), current == email else { throw RecoverySyncError.accountMismatch }
        let key = WhoopRecovery.pseudonymousAccountKey(userID: user.id)
        try repository.validateAccount(key)
        try await healthKitService.requestAuthorization()
        let importer = HistoryImporter(repository: repository, syncWindow: { window in
            try await self.syncEngine.synchronize(recoveryMode: .recent, resumeDeferred: false, historyWindow: window)
        }, syncRecovery: {
            let cutoff = self.repository.historyCutoff ?? Date()
            var history = try await self.recoveryPipeline.run(accountKey: key, mode: .history, now: cutoff, maxPages: Int.max)
            // Wider history already imported is retained; still discover data since its last live checkpoint.
            let recent = try await self.recoveryPipeline.run(accountKey: key, mode: .recent, now: cutoff)
            history.downloaded += recent.downloaded; history.written += recent.written
            history.revised += recent.revised; history.unchanged += recent.unchanged
            history.skippedExternal += recent.skippedExternal; history.unscorable += recent.unscorable
            history.invalid += recent.invalid; history.deferredAccess += recent.deferredAccess
            history.pending = recent.pending; history.recentCompleted = recent.recentCompleted
            if ![.completed, .historyLimited, .disabled].contains(recent.status) { history.status = recent.status }
            return history
        }, canContinue: {
            #if os(iOS)
            return UIApplication.shared.applicationState == .active
            #else
            return true
            #endif
        })
        importer.progressChanged = { [weak self] in self?.historyProgressChanged?() }
        do {
            let summary = try await importer.run(start: start)
            operationSummary = summary
            let run = try repository.createRejectedRun(startedAt: Date())
            try repository.finishRun(run, summary: summary, status: summary.hasIncompleteResults ? "partial" : "success")
            return summary
        } catch {
            var summary = importer.lastSummary
            summary.errors = [SensitiveTextSanitizer.redact(error.localizedDescription)]
            operationSummary = summary
            if let run = try? repository.createRejectedRun(startedAt: Date()) {
                try? repository.finishRun(run, summary: summary, status: error is CancellationError ? "cancelled" : "failed")
            }
            throw error
        }
    }

    func probeExistingCyclesSchema() async throws -> String {
        try await api.probeExistingCyclesSchema()
    }

    func probeRecoveryValues() async throws -> String {
        try await api.probeRecoveryValues()
    }

    func importRecoveryHistory() async throws -> SyncSummary {
        try acquireSyncLock(); defer { releaseSyncLock() }
        let started = Date()
        let user = try await api.fetchCurrentUser()
        let key = WhoopRecovery.pseudonymousAccountKey(userID: user.id)
        try repository.validateAccount(key)
        let run = try repository.createRejectedRun(startedAt: started)
        var summary = SyncSummary()
        do {
            summary.recovery = try await recoveryPipeline.run(accountKey: key, mode: .history, maxPages: Int.max)
            summary.elapsedSeconds = Date().timeIntervalSince(started)
            try repository.finishRun(run, summary: summary, status: "success")
            return summary
        } catch {
            summary.recovery = recoveryPipeline.lastSummary; summary.recovery.status = .issues
            summary.elapsedSeconds = Date().timeIntervalSince(started)
            summary.errors = [SensitiveTextSanitizer.redact(error.localizedDescription)]
            try? repository.finishRun(run, summary: summary, status: error is CancellationError ? "cancelled" : "failed")
            throw error
        }
    }

    func bindCurrentAccountManually() async throws {
        guard case let .authenticated(email) = authService.currentStatus() else { throw AutomatedSyncError.whoopNotConnected }
        let user = try await api.fetchCurrentUser()
        try Task.checkCancellation()
        guard case let .authenticated(currentEmail) = authService.currentStatus(), currentEmail == email else { throw RecoverySyncError.accountMismatch }
        try repository.bindAccountManually(WhoopRecovery.pseudonymousAccountKey(userID: user.id))
    }

    func synchronizeFromAutomation() async throws -> SyncSummary {
        // Shortcuts can start the intent twice at once; the second caller shares the first run.
        if let automationTask {
            AppLog.sync.info("Automation joined the sync already started by Shortcuts.")
            return try await automationTask.value
        }
        let task = Task { @MainActor in try await self.runAutomatedSync() }
        automationTask = task
        defer { automationTask = nil }
        return try await task.value
    }

    private func runAutomatedSync() async throws -> SyncSummary {
        try await waitForSyncLock()
        try acquireSyncLock(); defer { releaseSyncLock() }
        guard case .authenticated = authService.currentStatus() else {
            throw AutomatedSyncError.whoopNotConnected
        }

        try Self.validateAutomatedSetup(repository: repository)

        try healthKitService.validateExistingAuthorization()
        return try await syncEngine.synchronize(recoveryMode: .recent, resumeDeferred: false)
    }

    // A background launch for the intent can coincide with another operation that releases the lock shortly after.
    private func waitForSyncLock() async throws {
        var attempts = 0
        while let holder = syncLockHolder, attempts < 50 {
            if attempts == 0 { AppLog.sync.info("Automation waiting for \(holder, privacy: .public) to release the sync lock.") }
            attempts += 1
            try await Task.sleep(nanoseconds: 500_000_000)
        }
    }

    private func acquireSyncLock(_ operation: String = #function) throws {
        if let syncLockHolder {
            AppLog.sync.warning("Rejected \(operation, privacy: .public): \(syncLockHolder, privacy: .public) holds the sync lock.")
            throw LiveSyncRuntimeError.syncInProgress
        }
        syncLockHolder = operation
    }

    private func releaseSyncLock() {
        syncLockHolder = nil
    }

    static func validateAutomatedSetup(repository: SyncRepository) throws {
        try repository.ensureUsable()
        guard !repository.requiresManualAccountBinding else { throw SyncRepositoryError.accountBindingRequired }
        guard repository.hasCompletedSyncSetup else { throw AutomatedSyncError.initialManualSyncRequired }
        let checkpoints = try repository.checkpoints()
        guard checkpoints.lastSleepQueryEnd != nil, checkpoints.lastHeartRateEnd != nil else {
            throw AutomatedSyncError.initialManualSyncRequired
        }
    }
}

enum LiveSyncRuntimeError: Error, LocalizedError {
    case syncInProgress

    var errorDescription: String? {
        String(localized: "Another HealthDataBridge sync is still running. Try again when it finishes.")
    }
}

enum AutomatedSyncError: Error, LocalizedError {
    case whoopNotConnected
    case initialManualSyncRequired

    var errorDescription: String? {
        switch self {
        case .whoopNotConnected:
            return String(localized: "Open HealthDataBridge and connect your account before running the automation.")
        case .initialManualSyncRequired:
            return String(localized: "Complete sync setup and a first manual sync in HealthDataBridge before running the automation.")
        }
    }
}

private enum HKRecoverySetup {
    static func validBundle(_ bundle: String?) -> Bool {
        guard let bundle else { return true }
        return bundle.range(of: "^[A-Za-z0-9.-]{1,200}$", options: .regularExpression) != nil
    }
}
