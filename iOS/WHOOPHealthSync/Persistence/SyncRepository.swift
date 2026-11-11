import Foundation
import WHOOPHealthSyncCore

@MainActor
final class SyncRepository {
    private enum Keys {
        static let heartRateCheckpoint = "heartRateCheckpoint"
        static let sleepCheckpoint = "sleepCheckpoint"
        static let heartRateResolution = "heartRateResolution"
    }
    private static let deepDiveSleepIDPrefix = "deep-dive-sleep:"

    private let fileURL: URL
    private var snapshot: SyncStoreSnapshot
    private var committedSnapshot: SyncStoreSnapshot
    private(set) var loadError: Error?
    private var migrationBackupNeeded = false
    private let writeData: (Data, URL) throws -> Void
    private let maxStoredEvents = 500
    private let maxStoredRuns = 100

    init(fileURL: URL? = nil, writeData: ((Data, URL) throws -> Void)? = nil) {
        self.fileURL = fileURL ?? Self.defaultStoreURL()
        self.writeData = writeData ?? Self.protectedAtomicWrite
        do {
            self.snapshot = try Self.load(from: self.fileURL)
            let journalURL = self.fileURL.appendingPathExtension("recovery-wal")
            if let journal = try Self.readIfPresent(journalURL) {
                let pending = try JSONDecoder().decode([String: RecoveryPendingOperation].self, from: journal)
                self.snapshot.recovery.pendingOperations.merge(pending) { _, operation in operation }
            }
            if FileManager.default.fileExists(atPath: self.fileURL.path) {
                let bytes = try Data(contentsOf: self.fileURL)
                let object = try JSONSerialization.jsonObject(with: bytes) as? [String: Any]
                self.migrationBackupNeeded = (object?["schemaVersion"] as? Int ?? 1) == 1
            }
        } catch {
            self.snapshot = .empty
            self.loadError = SyncRepositoryError.storeUnavailable
        }
        self.committedSnapshot = self.snapshot
    }

    func ensureUsable() throws {
        if let loadError { throw loadError }
    }

    // Existing installations are recognized from their actual state, not a new onboarding flag.
    var hasCompletedSyncSetup: Bool {
        loadError == nil && (state("syncSetupCompleted")?.intValue == 1 || snapshot.recovery.configured ||
        snapshot.states[Keys.sleepCheckpoint] != nil || snapshot.states[Keys.heartRateCheckpoint] != nil ||
        requiresManualAccountBinding)
    }

    /// One protected atomic snapshot, including initial account binding. No intermediate HRV activation.
    func saveSyncSetup(recovery: RecoverySyncState, accountKey: String? = nil) throws {
        try ensureUsable()
        if let key = accountKey {
            guard !key.isEmpty, snapshot.linkedAccountKey == nil || snapshot.linkedAccountKey == key,
                  snapshot.recovery.accountKey == nil || snapshot.recovery.accountKey == key else {
                throw RecoverySyncError.accountMismatch
            }
            guard !requiresManualAccountBinding else { throw SyncRepositoryError.accountBindingRequired }
            snapshot.linkedAccountKey = key
        }
        snapshot.recovery = recovery
        snapshot.states["syncSetupCompleted"] = SyncStateRecord(key: "syncSetupCompleted", intValue: 1)
        try save()
    }

    func completeSyncSetup() throws {
        try ensureUsable()
        snapshot.states["syncSetupCompleted"] = SyncStateRecord(key: "syncSetupCompleted", intValue: 1)
        try save()
    }

    func historyWindow() throws -> TimeRange? {
        try ensureUsable()
        guard let start = state("historyNext")?.dateValue, let end = state("historyCutoff")?.dateValue,
              start < end else { return nil }
        return TimeRange(start: start, end: end)
    }

    var hasPendingHistoryImport: Bool { state("historyActive")?.intValue == 1 }

    var historyCutoff: Date? { state("historyCutoff")?.dateValue }
    var historyPhase: String? { state("historyPhase")?.stringValue }

    func beginHistory(start: Date, cutoff: Date, recovery: RecoverySyncState? = nil) throws {
        try ensureUsable()
        guard start < cutoff else { throw RecoverySyncError.invalidRecord }
        snapshot.states["historyStart"] = SyncStateRecord(key: "historyStart", dateValue: start)
        snapshot.states["historyNext"] = SyncStateRecord(key: "historyNext", dateValue: start)
        snapshot.states["historyCutoff"] = SyncStateRecord(key: "historyCutoff", dateValue: cutoff)
        snapshot.states["historyActive"] = SyncStateRecord(key: "historyActive", intValue: 1)
        snapshot.states["historyPhase"] = SyncStateRecord(key: "historyPhase", stringValue: "sleepHeartRate")
        if let recovery { snapshot.recovery = recovery }
        try save()
    }

    func advanceHistory(to date: Date) throws {
        try ensureUsable()
        snapshot.states["historyNext"] = SyncStateRecord(key: "historyNext", dateValue: date)
        if date >= (historyCutoff ?? .distantFuture) {
            snapshot.states["historyPhase"] = SyncStateRecord(key: "historyPhase", stringValue: "recovery")
        }
        try save()
    }

    func finishHistory() throws {
        try ensureUsable()
        snapshot.states["historyActive"] = SyncStateRecord(key: "historyActive", intValue: 0)
        snapshot.states["historyPhase"] = SyncStateRecord(key: "historyPhase", stringValue: "finished")
        try save()
    }

    var requiresManualAccountBinding: Bool {
        guard snapshot.linkedAccountKey == nil else { return false }
        return snapshot.states[Keys.heartRateCheckpoint] != nil || snapshot.states[Keys.sleepCheckpoint] != nil
            || !snapshot.sleepRecords.isEmpty || !snapshot.recovery.records.isEmpty
            || !snapshot.recovery.pendingOperations.isEmpty || !snapshot.recovery.pendingItems.isEmpty
            || snapshot.recovery.initialImportCutoff != nil || snapshot.recovery.lastDiscoveryEnd != nil
            || snapshot.recovery.historicalCursor != nil || snapshot.recovery.historicalPagesConfirmed > 0
            || snapshot.runs.contains { $0.stagesWritten > 0 || $0.heartRateWritten > 0 || $0.recovery.written > 0 }
    }

    func validateAccount(_ key: String) throws {
        try ensureUsable()
        guard !key.isEmpty else { throw RecoverySyncError.accountMismatch }
        if let linked = snapshot.linkedAccountKey {
            guard linked == key else { throw RecoverySyncError.accountMismatch }
            return
        }
        if let recoveryAccount = snapshot.recovery.accountKey, recoveryAccount != key {
            throw RecoverySyncError.accountMismatch
        }
        guard !requiresManualAccountBinding else { throw SyncRepositoryError.accountBindingRequired }
        // A new store has no previous progress to attribute. The caller supplies the authenticated ID.
        try bindAccountManually(key)
    }

    /// Explicit confirmation binds legacy progress; automation never guesses its historical owner.
    func bindAccountManually(_ key: String) throws {
        try ensureUsable()
        guard !key.isEmpty else { throw RecoverySyncError.accountMismatch }
        if let linked = snapshot.linkedAccountKey, linked != key { throw RecoverySyncError.accountMismatch }
        if let recoveryAccount = snapshot.recovery.accountKey, recoveryAccount != key { throw RecoverySyncError.accountMismatch }
        snapshot.linkedAccountKey = key
        try save()
    }

    func deferredWindow(for type: String) throws -> TimeRange? {
        try ensureUsable()
        guard let start = state("deferred-\(type)-start")?.dateValue,
              let end = state("deferred-\(type)-end")?.dateValue else { return nil }
        return TimeRange(start: start, end: end)
    }
    func setDeferredWindow(_ window: TimeRange?, for type: String) throws {
        try ensureUsable()
        if let window {
            let old = try deferredWindow(for: type)
            snapshot.states["deferred-\(type)-start"] = SyncStateRecord(key: "deferred-\(type)-start", dateValue: min(old?.start ?? window.start, window.start))
            snapshot.states["deferred-\(type)-end"] = SyncStateRecord(key: "deferred-\(type)-end", dateValue: max(old?.end ?? window.end, window.end))
        } else {
            snapshot.states.removeValue(forKey: "deferred-\(type)-start")
            snapshot.states.removeValue(forKey: "deferred-\(type)-end")
        }
        try save()
    }

    func recoveryState() throws -> RecoverySyncState {
        try ensureUsable()
        return snapshot.recovery
    }

    func prepareRecoveryOperation(_ operation: RecoveryPendingOperation) throws {
        try ensureUsable()
        var pending = snapshot.recovery.pendingOperations
        pending[operation.identifier] = operation
        let bytes = try JSONEncoder().encode(pending)
        try FileManager.default.createDirectory(at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        do { try writeData(bytes, fileURL.appendingPathExtension("recovery-wal")) }
        catch { throw SyncRepositoryError.storeWriteFailed }
        snapshot.recovery.pendingOperations = pending
        committedSnapshot.recovery.pendingOperations = pending
    }

    func commitRecoveryState(_ state: RecoverySyncState) throws {
        try ensureUsable()
        if let key = state.accountKey { try validateAccount(key) }
        snapshot.recovery = state
        try save()
        // Main store commits first. A stale WAL after interrupted cleanup is safe to reconcile on restart.
        if FileManager.default.fileExists(atPath: fileURL.appendingPathExtension("recovery-wal").path) {
            do { try Self.protectedAtomicWrite(try JSONEncoder().encode(state.pendingOperations), fileURL.appendingPathExtension("recovery-wal")) }
            catch { AppLog.persistence.warning("Recovery journal cleanup deferred; committed records retained.") }
        }
    }

    func checkpoints() throws -> SyncCheckpointState {
        try ensureUsable()
        return SyncCheckpointState(
            lastHeartRateEnd: state(Keys.heartRateCheckpoint)?.dateValue,
            lastSleepQueryEnd: state(Keys.sleepCheckpoint)?.dateValue,
            lastHeartRateResolution: state(Keys.heartRateResolution)?.intValue
        )
    }

    func diagnostics() -> SyncDiagnostics {
        let lastRun = snapshot.runs.max { lhs, rhs in
            lhs.startedAt < rhs.startedAt
        }
        let recentEvents = snapshot.events
            .sorted { $0.timestamp > $1.timestamp }
            .prefix(100)
        return SyncDiagnostics(
            deferredSleepWindow: try? deferredWindow(for: "sleep"),
            deferredHeartRateWindow: try? deferredWindow(for: "heartRate"),
            lastHeartRateCheckpoint: state(Keys.heartRateCheckpoint)?.dateValue,
            lastSleepCheckpoint: state(Keys.sleepCheckpoint)?.dateValue,
            heartRateResolution: state(Keys.heartRateResolution)?.intValue,
            lastRunStartedAt: lastRun?.startedAt,
            lastRunFinishedAt: lastRun?.finishedAt,
            lastRunStatus: lastRun?.status,
            lastRunErrorsText: lastRun?.errorsText ?? "",
            recordedSleepCount: snapshot.sleepRecords.count,
            recentEvents: Array(recentEvents)
        )
    }

    func appendEvent(runID: UUID?, level: String, category: String, message: String) throws {
        snapshot.events.append(
            SyncEventRecord(
                runID: runID,
                level: level,
                category: category,
                message: SensitiveTextSanitizer.redact(message)
            )
        )
        if snapshot.events.count > maxStoredEvents {
            snapshot.events.removeFirst(snapshot.events.count - maxStoredEvents)
        }
        try save()
    }

    func setHeartRateCheckpoint(_ date: Date, resolution: Int) throws {
        var checkpoint = mutableState(Keys.heartRateCheckpoint)
        checkpoint.dateValue = date
        checkpoint.updatedAt = Date()
        snapshot.states[Keys.heartRateCheckpoint] = checkpoint

        var resolutionState = mutableState(Keys.heartRateResolution)
        resolutionState.intValue = resolution
        resolutionState.updatedAt = Date()
        snapshot.states[Keys.heartRateResolution] = resolutionState
        try save()
    }

    func setSleepCheckpoint(_ date: Date) throws {
        var checkpoint = mutableState(Keys.sleepCheckpoint)
        checkpoint.dateValue = date
        checkpoint.updatedAt = Date()
        snapshot.states[Keys.sleepCheckpoint] = checkpoint
        try save()
    }

    func sleepRecord(for whoopSleepID: String) -> SleepSyncRecord? {
        snapshot.sleepRecords[whoopSleepID]
    }

    func upsertSleepRecord(session: SleepSession, fingerprint: String, result: String) throws {
        if var record = sleepRecord(for: session.whoopSleepID) {
            if record.fingerprint != fingerprint {
                record.syncVersion += 1
            }
            record.sourceUpdatedAt = session.sourceUpdatedAt
            record.start = session.start
            record.end = session.end
            record.isNap = session.isNap
            record.fingerprint = fingerprint
            record.lastProcessedAt = Date()
            record.lastResult = result
            snapshot.sleepRecords[session.whoopSleepID] = record
        } else {
            if let matchingKey = matchingSleepRecordKey(fingerprint: fingerprint, session: session),
               var record = snapshot.sleepRecords[matchingKey] {
                let targetKey = preferredSleepRecordKey(existing: matchingKey, incoming: session.whoopSleepID)
                record.whoopSleepID = targetKey
                record.sourceUpdatedAt = session.sourceUpdatedAt
                record.start = session.start
                record.end = session.end
                record.isNap = session.isNap
                record.fingerprint = fingerprint
                record.lastProcessedAt = Date()
                record.lastResult = result
                if targetKey != matchingKey {
                    snapshot.sleepRecords.removeValue(forKey: matchingKey)
                }
                snapshot.sleepRecords[targetKey] = record
                try save()
                return
            }

            snapshot.sleepRecords[session.whoopSleepID] = SleepSyncRecord(
                whoopSleepID: session.whoopSleepID,
                sourceUpdatedAt: session.sourceUpdatedAt,
                start: session.start,
                end: session.end,
                isNap: session.isNap,
                fingerprint: fingerprint,
                syncVersion: 1,
                lastProcessedAt: Date(),
                lastResult: result
            )
        }
        try save()
    }

    private func matchingSleepRecordKey(fingerprint: String, session: SleepSession) -> String? {
        snapshot.sleepRecords
            .filter { key, record in
                key != session.whoopSleepID
                    && record.fingerprint == fingerprint
                    && record.start == session.start
                    && record.end == session.end
                    && record.isNap == session.isNap
            }
            .max { lhs, rhs in
                lhs.value.lastProcessedAt < rhs.value.lastProcessedAt
            }?
            .key
    }

    private func preferredSleepRecordKey(existing: String, incoming: String) -> String {
        if existing.hasPrefix(Self.deepDiveSleepIDPrefix) && !incoming.hasPrefix(Self.deepDiveSleepIDPrefix) {
            return incoming
        }
        if !existing.hasPrefix(Self.deepDiveSleepIDPrefix) && incoming.hasPrefix(Self.deepDiveSleepIDPrefix) {
            return existing
        }
        return incoming
    }

    func createRejectedRun(startedAt: Date) throws -> UUID {
        let run = SyncRunRecord(startedAt: startedAt)
        snapshot.runs.append(run)
        try save()
        return run.id
    }

    func createRun(startedAt: Date, plan: IncrementalSyncPlan) throws -> UUID {
        var run = SyncRunRecord(startedAt: startedAt)
        let sleepQueryWindow = SyncWindowPlanner.sleepQueryWindow(for: plan)
        run.heartRateWindowStart = plan.heartRateWindow.start
        run.heartRateWindowEnd = plan.heartRateWindow.end
        run.sleepWindowStart = sleepQueryWindow.start
        run.sleepWindowEnd = sleepQueryWindow.end
        snapshot.runs.append(run)
        try save()
        return run.id
    }

    func finishRun(_ runID: UUID, summary: SyncSummary, status: String) throws {
        guard let index = snapshot.runs.firstIndex(where: { $0.id == runID }) else {
            throw SyncRepositoryError.missingRun(runID)
        }
        snapshot.runs[index].finishedAt = Date()
        snapshot.runs[index].status = status
        snapshot.runs[index].sleepsDownloaded = summary.sleepsDownloaded
        snapshot.runs[index].sleepsWritten = summary.sleepsWritten
        snapshot.runs[index].sleepsUnchanged = summary.sleepsUnchanged
        snapshot.runs[index].sleepsRevised = summary.sleepsRevised
        snapshot.runs[index].sleepsDiscardedOutOfWindow = summary.sleepsDiscardedOutOfWindow
        snapshot.runs[index].stagesWritten = summary.stagesWritten
        snapshot.runs[index].stagesSkipped = summary.stagesSkipped
        snapshot.runs[index].stagesRemoved = summary.stagesRemoved
        snapshot.runs[index].heartRateDownloaded = summary.heartRateDownloaded
        snapshot.runs[index].heartRateDiscardedOutOfWindow = summary.heartRateDiscardedOutOfWindow
        snapshot.runs[index].heartRateWritten = summary.heartRateWritten
        snapshot.runs[index].heartRateSkipped = summary.heartRateSkipped
        snapshot.runs[index].heartRateRemoved = summary.heartRateRemoved
        snapshot.runs[index].effectiveHeartRateResolution = summary.effectiveHeartRateResolution
        snapshot.runs[index].elapsedSeconds = summary.elapsedSeconds
        snapshot.runs[index].recovery = summary.recovery
        snapshot.runs[index].errorsText = summary.errors.map(SensitiveTextSanitizer.redact).joined(separator: "\n")
        trimStoredRuns()
        try save()
    }

    private func trimStoredRuns() {
        guard snapshot.runs.count > maxStoredRuns else { return }
        let retainedIDs = Set(
            snapshot.runs
                .sorted { lhs, rhs in
                    if lhs.startedAt == rhs.startedAt {
                        return lhs.id.uuidString > rhs.id.uuidString
                    }
                    return lhs.startedAt > rhs.startedAt
                }
                .prefix(maxStoredRuns)
                .map(\.id)
        )
        snapshot.runs.removeAll { !retainedIDs.contains($0.id) }
    }

    private func state(_ key: String) -> SyncStateRecord? {
        snapshot.states[key]
    }

    private func mutableState(_ key: String) -> SyncStateRecord {
        if let existing = state(key) {
            return existing
        }
        return SyncStateRecord(key: key)
    }

    private func save() throws {
        do {
            try ensureUsable()
            try FileManager.default.createDirectory(
                at: fileURL.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            encoder.dateEncodingStrategy = .iso8601
            let data = try encoder.encode(snapshot)
            if migrationBackupNeeded {
                let original = try Data(contentsOf: fileURL)
                let backupURL = fileURL.appendingPathExtension("v1-backup")
                // Never overwrite the original migration evidence on a retry.
                if !FileManager.default.fileExists(atPath: backupURL.path) {
                    try Self.protectedAtomicWrite(original, backupURL)
                }
            }
            try writeData(data, fileURL)
            committedSnapshot = snapshot
            migrationBackupNeeded = false
        } catch {
            snapshot = committedSnapshot
            AppLog.persistence.error("Sync repository save failed; committed state retained.")
            throw SyncRepositoryError.storeWriteFailed
        }
    }

    private static func protectedAtomicWrite(_ data: Data, _ url: URL) throws {
        #if os(iOS)
        try data.write(to: url, options: [.atomic, .completeFileProtection])
        #else
        try data.write(to: url, options: [.atomic])
        #endif
    }

    private static func readIfPresent(_ fileURL: URL) throws -> Data? {
        do { return try Data(contentsOf: fileURL) }
        catch {
            let failure = error as NSError
            // fileExists can also be false for an inaccessible protected directory.
            guard failure.domain == NSCocoaErrorDomain, failure.code == NSFileReadNoSuchFileError else { throw error }
            return nil
        }
    }

    private static func load(from fileURL: URL) throws -> SyncStoreSnapshot {
        guard let data = try readIfPresent(fileURL) else { return .empty }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try decoder.decode(SyncStoreSnapshot.self, from: data)
    }

    private static func defaultStoreURL() -> URL {
        let applicationSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
        let base = applicationSupport ?? FileManager.default.temporaryDirectory
        return base
            .appendingPathComponent("WHOOPHealthSync", isDirectory: true)
            .appendingPathComponent("sync-store.json", isDirectory: false)
    }

}

enum SyncRepositoryError: Error, LocalizedError {
    case missingRun(UUID)
    case storeUnavailable, unsupportedSchema, storeWriteFailed, accountBindingRequired

    var errorDescription: String? {
        switch self {
        case .accountBindingRequired:
            return AppLocalization.string("Confirm the WHOOP account for saved sync progress in Options before synchronizing.")
        case .storeWriteFailed: return "Local sync data could not be committed; confirmed state retained."
        case .storeUnavailable: return "Local sync data cannot be read; original store retained and synchronization blocked."
        case .unsupportedSchema: return "Local sync schema is unsupported; original store retained."
        case let .missingRun(id):
            return "Sync run \(id.uuidString) was not found in local persistence."
        }
    }
}

extension SyncRepository: RecoveryStatePersisting {}
