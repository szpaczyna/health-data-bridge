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
    private let syncCoordinator = SyncCoordinator()
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
        let recoveryPipeline = RecoverySyncPipeline(provider: provider, health: recoveryAdapter, persistence: repository, appBundle: Bundle.main.bundleIdentifier ?? "com.joselourido.WHOOPHealthSync", canContinueHistory: Self.appIsActive, canContinueSync: {
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

    func requestHealthKitAuthorization() async throws {
        try await healthKitService.requestAuthorization()
    }

    func synchronize() async throws -> SyncSummary {
        operationSummary = nil
        try acquireSyncLock(); defer { releaseSyncLock() }
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

    private static func appIsActive() -> Bool {
        #if os(iOS)
        return UIApplication.shared.applicationState == .active
        #else
        return true
        #endif
    }

    func importHistory(start: Date?) async throws -> SyncSummary {
        operationSummary = nil
        try acquireSyncLock(); defer { releaseSyncLock() }
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
            if !recent.status.isSettled { history.status = recent.status }
            return history
        }, canContinue: { Self.appIsActive() })
        importer.progressChanged = { [weak self] in self?.historyProgressChanged?() }
        do {
            let summary = try await importer.run(start: start)
            operationSummary = summary
            let run = try repository.createRejectedRun(startedAt: Date())
            try repository.finishRun(run, summary: summary, status: summary.hasIncompleteResults ? .partial : .success)
            return summary
        } catch {
            var summary = importer.lastSummary
            summary.errors = [SensitiveTextSanitizer.redact(error.localizedDescription)]
            operationSummary = summary
            if let run = try? repository.createRejectedRun(startedAt: Date()) {
                try? repository.finishRun(run, summary: summary, status: error is CancellationError ? .cancelled : .failed)
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

    func bindCurrentAccountManually() async throws {
        guard case let .authenticated(email) = authService.currentStatus() else { throw AutomatedSyncError.whoopNotConnected }
        let user = try await api.fetchCurrentUser()
        try Task.checkCancellation()
        guard case let .authenticated(currentEmail) = authService.currentStatus(), currentEmail == email else { throw RecoverySyncError.accountMismatch }
        try repository.bindAccountManually(WhoopRecovery.pseudonymousAccountKey(userID: user.id))
    }

    func synchronizeFromAutomation() async throws -> SyncSummary {
        try await syncCoordinator.runAutomation(lockOperation: "runAutomatedSync()") { try await self.runAutomatedSync() }
    }

    private func runAutomatedSync() async throws -> SyncSummary {
        guard case .authenticated = authService.currentStatus() else {
            throw AutomatedSyncError.whoopNotConnected
        }

        try Self.validateAutomatedSetup(repository: repository)

        try healthKitService.validateExistingAuthorization()
        return try await syncEngine.synchronize(recoveryMode: .recent, resumeDeferred: false, origin: .automation)
    }

    private func acquireSyncLock(_ operation: String = #function) throws {
        try syncCoordinator.acquire(operation)
    }

    private func releaseSyncLock() {
        syncCoordinator.release()
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
