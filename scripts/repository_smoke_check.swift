import Foundation
import WHOOPHealthSyncCore

@main
struct RepositorySmokeCheck {
    @MainActor
    static func main() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("WHOOPHealthSyncRepositorySmoke-\(UUID().uuidString)", isDirectory: true)
        let fileURL = directory.appendingPathComponent("sync-store.json", isDirectory: false)
        defer {
            try? FileManager.default.removeItem(at: directory)
        }

        let repository = SyncRepository(fileURL: fileURL)
        try expect(try repository.checkpoints() == SyncCheckpointState(lastHeartRateEnd: nil, lastSleepQueryEnd: nil), "Fresh repository should have empty checkpoints.")
        expect(repository.diagnostics() == .empty, "Fresh repository should have empty diagnostics.")

        try repository.setHeartRateCheckpoint(date(100), resolution: 6)
        try repository.setSleepCheckpoint(date(200))

        let session = try SleepNormalizer.normalize(
            SleepSession(
                whoopSleepID: "sleep-smoke",
                sourceUpdatedAt: date(210),
                start: date(0),
                end: date(120),
                timezoneOffsetSeconds: nil,
                isNap: false,
                stages: [
                    SleepStageInterval(start: date(0), end: date(60), stage: .core),
                    SleepStageInterval(start: date(60), end: date(120), stage: .rem)
                ]
            )
        )
        let fingerprint = SleepFingerprint.make(for: session)
        try repository.upsertSleepRecord(session: session, fingerprint: fingerprint, result: "smoke")

        let plan = SyncWindowPlanner.makePlan(
            now: date(300),
            checkpoints: try repository.checkpoints(),
            heartRateStepSeconds: 6
        )
        let runID = try repository.createRun(startedAt: date(300), plan: plan)
        var summary = SyncSummary()
        summary.sleepsDownloaded = 1
        summary.sleepsWritten = 1
        summary.sleepsUnchanged = 2
        summary.sleepsRevised = 3
        summary.sleepsDiscardedOutOfWindow = 4
        summary.stagesWritten = 2
        summary.heartRateDownloaded = 5
        summary.heartRateDiscardedOutOfWindow = 6
        summary.heartRateWritten = 3
        summary.heartRateSkipped = 7
        summary.heartRateRemoved = 8
        summary.effectiveHeartRateResolution = 60
        summary.elapsedSeconds = 1.25
        summary.errors = [
            "smoke-warning for jose@example.com Authorization: Bearer secret-token password=secret-password refreshToken=refresh-secret jwt=header.payload.signature"
        ]
        try repository.appendEvent(
            runID: runID,
            level: "info",
            category: "smoke",
            message: "repository event for jose@example.com Authorization: Bearer secret-token password=secret-password"
        )
        try repository.finishRun(runID, summary: summary, status: .partial)

        let reloaded = SyncRepository(fileURL: fileURL)
        try expect(
            try reloaded.checkpoints() == SyncCheckpointState(
                lastHeartRateEnd: date(100),
                lastSleepQueryEnd: date(200),
                lastHeartRateResolution: 6
            ),
            "Reloaded repository should preserve checkpoints and HR resolution."
        )
        expect(reloaded.sleepRecord(for: "sleep-smoke")?.fingerprint == fingerprint, "Reloaded repository should preserve sleep fingerprints.")
        let diagnostics = reloaded.diagnostics()
        expect(diagnostics.lastHeartRateCheckpoint == date(100), "Diagnostics should expose HR checkpoint.")
        expect(diagnostics.lastSleepCheckpoint == date(200), "Diagnostics should expose sleep checkpoint.")
        expect(diagnostics.heartRateResolution == 6, "Diagnostics should expose HR resolution.")
        expect(diagnostics.lastRunStatus == .partial, "Diagnostics should expose last run status.")
        expect(diagnostics.lastRunErrorsText.contains("[redacted-email]"), "Diagnostics should expose sanitized last-run errors.")
        expect(diagnostics.lastRunErrorsText.contains("Bearer [redacted-token]"), "Diagnostics should redact bearer tokens in last-run errors.")
        expect(!diagnostics.lastRunErrorsText.contains("secret-password"), "Diagnostics should redact passwords in last-run errors.")
        expect(diagnostics.recordedSleepCount == 1, "Diagnostics should expose recorded sleep count.")
        expect(diagnostics.recentEvents.first?.message.contains("[redacted-email]") == true, "Diagnostics should expose sanitized persisted events.")
        expect(diagnostics.recentEvents.first?.message.contains("Bearer [redacted-token]") == true, "Diagnostics should redact bearer tokens in persisted events.")
        expect(diagnostics.recentEvents.first?.runID == runID, "Persisted events should keep their run ID.")
        let persistedJSON = try String(contentsOf: fileURL, encoding: .utf8)
        expect(!persistedJSON.contains("jose@example.com"), "Persisted JSON should redact emails.")
        expect(!persistedJSON.contains("secret-token"), "Persisted JSON should redact bearer token material.")
        expect(!persistedJSON.contains("secret-password"), "Persisted JSON should redact password material.")
        expect(!persistedJSON.contains("refresh-secret"), "Persisted JSON should redact refresh token material.")
        expect(!persistedJSON.contains("header.payload.signature"), "Persisted JSON should redact JWT-like material.")
        expect(persistedJSON.contains(#""sleepsWritten" : 1"#), "Persisted run should store sleepsWritten.")
        expect(persistedJSON.contains(#""sleepsUnchanged" : 2"#), "Persisted run should store sleepsUnchanged.")
        expect(persistedJSON.contains(#""sleepsRevised" : 3"#), "Persisted run should store sleepsRevised.")
        expect(persistedJSON.contains(#""heartRateDownloaded" : 5"#), "Persisted run should store HR download count.")
        expect(persistedJSON.contains(#""heartRateDiscardedOutOfWindow" : 6"#), "Persisted run should store HR discarded count.")
        expect(persistedJSON.contains(#""heartRateSkipped" : 7"#), "Persisted run should store HR skipped count.")
        expect(persistedJSON.contains(#""heartRateRemoved" : 8"#), "Persisted run should store HR removed count.")
        expect(persistedJSON.contains(#""effectiveHeartRateResolution" : 60"#), "Persisted run should store effective HR resolution.")
        expect(persistedJSON.contains(#""elapsedSeconds" : 1.25"#), "Persisted run should store elapsed seconds.")

        let migrationDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("WHOOPHealthSyncRepositoryMigration-\(UUID().uuidString)", isDirectory: true)
        let migrationURL = migrationDirectory.appendingPathComponent("sync-store.json", isDirectory: false)
        defer {
            try? FileManager.default.removeItem(at: migrationDirectory)
        }
        let migrationRepository = SyncRepository(fileURL: migrationURL)
        let fallbackSession = try sleepSession(id: "deep-dive-sleep:2026-07-12", start: date(1_000))
        let realSession = try sleepSession(id: "real-activity-id", start: date(1_000))
        let contentFingerprint = SleepFingerprint.make(for: fallbackSession)
        try migrationRepository.upsertSleepRecord(session: fallbackSession, fingerprint: contentFingerprint, result: "fallback")
        try migrationRepository.upsertSleepRecord(session: realSession, fingerprint: contentFingerprint, result: "real")
        expect(migrationRepository.sleepRecord(for: "deep-dive-sleep:2026-07-12") == nil, "Fallback sleep record should be consolidated into the real activity ID.")
        expect(migrationRepository.sleepRecord(for: "real-activity-id")?.fingerprint == contentFingerprint, "Real activity ID should keep the content fingerprint.")
        expect(migrationRepository.diagnostics().recordedSleepCount == 1, "Fallback-to-real consolidation should keep one local sleep record.")

        try migrationRepository.upsertSleepRecord(session: fallbackSession, fingerprint: contentFingerprint, result: "fallback-again")
        expect(migrationRepository.sleepRecord(for: "real-activity-id") != nil, "A later fallback import should not downgrade an existing real activity ID record.")
        expect(migrationRepository.sleepRecord(for: "deep-dive-sleep:2026-07-12") == nil, "A later fallback import should still not create a duplicate synthetic record.")
        expect(migrationRepository.diagnostics().recordedSleepCount == 1, "Real-to-fallback repeat should stay consolidated.")

        let legacyDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("WHOOPHealthSyncRepositoryLegacy-\(UUID().uuidString)", isDirectory: true)
        let legacyURL = legacyDirectory.appendingPathComponent("sync-store.json", isDirectory: false)
        defer {
            try? FileManager.default.removeItem(at: legacyDirectory)
        }
        try FileManager.default.createDirectory(at: legacyDirectory, withIntermediateDirectories: true)
        let legacyJSON = """
        {
          "runs": [
            {
              "id": "00000000-0000-0000-0000-000000000001",
              "startedAt": "1970-01-01T00:00:00Z",
              "status": "success",
              "sleepsDownloaded": 1,
              "stagesWritten": 2,
              "stagesSkipped": 0,
              "stagesRemoved": 0,
              "heartRateDownloaded": 3,
              "heartRateWritten": 4,
              "heartRateSkipped": 0,
              "heartRateRemoved": 0,
              "errorsText": "legacy one\\nlegacy two"
            }
          ],
          "sleepRecords": {},
          "states": {}
        }
        """
        try Data(legacyJSON.utf8).write(to: legacyURL, options: [.atomic])
        let legacyRepository = SyncRepository(fileURL: legacyURL)
        expect(legacyRepository.diagnostics().lastRunStatus == .success, "Repository should load legacy run records that lack newer counters.")
        expect(legacyRepository.diagnostics().recentEvents.isEmpty, "Repository should load legacy stores that lack events.")
        let legacyRun = legacyRepository.latestFinishedRun()
        expect(legacyRun?.sleepResult == .notAttempted && legacyRun?.heartRateResult == .notAttempted, "Legacy runs without phase results should decode as not attempted.")
        expect(legacyRun.map(SyncSummary.init(record:))?.errors == ["legacy one", "legacy two"], "Legacy runs without an errors array should split errorsText.")

        let statusJSON = """
        [
          {"id": "00000000-0000-0000-0000-000000000002", "startedAt": "1970-01-01T00:00:00Z", "status": "success"},
          {"id": "00000000-0000-0000-0000-000000000003", "startedAt": "1970-01-01T00:00:00Z", "status": "partial"},
          {"id": "00000000-0000-0000-0000-000000000004", "startedAt": "1970-01-01T00:00:00Z", "status": "bogus"}
        ]
        """
        let statusDecoder = JSONDecoder()
        statusDecoder.dateDecodingStrategy = .iso8601
        let statusRuns = try statusDecoder.decode([SyncRunRecord].self, from: Data(statusJSON.utf8))
        expect(statusRuns.map(\.status) == [.success, .partial, .unknown], "Legacy string statuses should decode to matching cases and unknown strings to unknown.")
        let statusEncoder = JSONEncoder()
        statusEncoder.dateEncodingStrategy = .iso8601
        let encodedRuns = try JSONSerialization.jsonObject(with: statusEncoder.encode(statusRuns)) as? [[String: Any]] ?? []
        expect(encodedRuns.map { $0["status"] as? String } == ["success", "partial", "unknown"], "Run statuses should re-encode as raw strings.")

        let resultsDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("WHOOPHealthSyncRepositoryResults-\(UUID().uuidString)", isDirectory: true)
        let resultsURL = resultsDirectory.appendingPathComponent("sync-store.json", isDirectory: false)
        defer {
            try? FileManager.default.removeItem(at: resultsDirectory)
        }
        let resultsRepository = SyncRepository(fileURL: resultsURL)
        let resultsPlan = SyncWindowPlanner.makePlan(
            now: date(5_000),
            checkpoints: SyncCheckpointState(lastHeartRateEnd: nil, lastSleepQueryEnd: nil),
            heartRateStepSeconds: 6
        )
        let resultsRunID = try resultsRepository.createRun(startedAt: date(5_000), plan: resultsPlan)
        let resultsSleepWindow = SyncWindowPlanner.sleepQueryWindow(for: resultsPlan)
        var resultsSummary = SyncSummary()
        resultsSummary.sleepResult = .updated
        resultsSummary.heartRateResult = .failed
        resultsSummary.recovery.status = .completed
        resultsSummary.recovery.written = 3
        resultsSummary.sleepsDownloaded = 1
        resultsSummary.sleepsWritten = 2
        resultsSummary.sleepsUnchanged = 3
        resultsSummary.sleepsRevised = 4
        resultsSummary.sleepsDiscardedOutOfWindow = 5
        resultsSummary.stagesWritten = 6
        resultsSummary.stagesSkipped = 7
        resultsSummary.stagesRemoved = 8
        resultsSummary.heartRateDownloaded = 9
        resultsSummary.heartRateWritten = 10
        resultsSummary.heartRateSkipped = 11
        resultsSummary.heartRateRemoved = 12
        resultsSummary.heartRateDiscardedOutOfWindow = 13
        resultsSummary.effectiveHeartRateResolution = 60
        resultsSummary.heartRateWindowStart = resultsPlan.heartRateWindow.start
        resultsSummary.heartRateWindowEnd = resultsPlan.heartRateWindow.end
        resultsSummary.sleepQueryWindowStart = resultsSleepWindow.start
        resultsSummary.sleepQueryWindowEnd = resultsSleepWindow.end
        resultsSummary.elapsedSeconds = 2.5
        resultsSummary.errors = ["first failure", "second failure"]
        try resultsRepository.finishRun(resultsRunID, summary: resultsSummary, status: .partial)
        _ = try resultsRepository.createRun(startedAt: date(6_000), plan: resultsPlan)
        let resultsReloaded = SyncRepository(fileURL: resultsURL)
        let resultsRun = resultsReloaded.latestFinishedRun()
        expect(resultsRun?.id == resultsRunID, "latestFinishedRun should skip newer runs that are still running.")
        expect(resultsRun?.sleepResult == .updated && resultsRun?.heartRateResult == .failed, "Reloaded run should preserve phase results.")
        expect(resultsRun.map(SyncSummary.init(record:)) == resultsSummary, "A reloaded run should rebuild the original summary.")

        let errorsDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("WHOOPHealthSyncRepositoryErrors-\(UUID().uuidString)", isDirectory: true)
        let errorsURL = errorsDirectory.appendingPathComponent("sync-store.json", isDirectory: false)
        defer {
            try? FileManager.default.removeItem(at: errorsDirectory)
        }
        let errorsRepository = SyncRepository(fileURL: errorsURL)
        for (offset, errors) in [["line one\nline two", "second"], [""]].enumerated() {
            let errorsRunID = try errorsRepository.createRun(startedAt: date(7_000 + TimeInterval(offset)), plan: resultsPlan)
            var errorsSummary = SyncSummary()
            errorsSummary.sleepResult = .updated
            errorsSummary.heartRateResult = .updated
            errorsSummary.recovery.status = .completed
            var cleanSummary = errorsSummary
            cleanSummary.errors = []
            expect(!cleanSummary.hasIncompleteResults, "Only errors should make the round-trip summary incomplete.")
            errorsSummary.errors = errors
            try errorsRepository.finishRun(errorsRunID, summary: errorsSummary, status: .partial)
            let errorsRun = SyncRepository(fileURL: errorsURL).latestFinishedRun()
            let rebuilt = errorsRun.map(SyncSummary.init(record:))
            expect(rebuilt?.errors == errors, "A reloaded run should rebuild errors exactly: \(errors)")
            expect(rebuilt?.hasIncompleteResults == true, "A reloaded run with errors should stay incomplete: \(errors)")
            expect(errorsRun?.errorsText == errors.joined(separator: "\n"), "errorsText should keep the newline-joined errors: \(errors)")
        }

        let boundedDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("WHOOPHealthSyncRepositoryBoundedRuns-\(UUID().uuidString)", isDirectory: true)
        let boundedURL = boundedDirectory.appendingPathComponent("sync-store.json", isDirectory: false)
        defer {
            try? FileManager.default.removeItem(at: boundedDirectory)
        }
        let boundedRepository = SyncRepository(fileURL: boundedURL)
        let boundedPlan = SyncWindowPlanner.makePlan(
            now: date(10_000),
            checkpoints: SyncCheckpointState(lastHeartRateEnd: nil, lastSleepQueryEnd: nil),
            heartRateStepSeconds: 6
        )
        for offset in 0..<125 {
            let run = try boundedRepository.createRun(
                startedAt: date(TimeInterval(offset)),
                plan: boundedPlan
            )
            var runSummary = SyncSummary()
            runSummary.sleepsDownloaded = offset
            try boundedRepository.finishRun(run, summary: runSummary, status: .success)
        }
        let boundedJSON = try Data(contentsOf: boundedURL)
        let boundedObject = try JSONSerialization.jsonObject(with: boundedJSON, options: []) as? [String: Any]
        let boundedRuns = boundedObject?["runs"] as? [[String: Any]] ?? []
        expect(boundedRuns.count == 100, "Repository should keep a bounded run history.")
        let boundedDiagnostics = boundedRepository.diagnostics()
        expect(boundedDiagnostics.lastRunStartedAt == date(124), "Bounded run trimming should retain the newest run for diagnostics.")
        expect(!boundedRuns.contains { $0["sleepsDownloaded"] as? Int == 0 }, "Bounded run trimming should remove oldest runs first.")

        // V2 failures must preserve both the original bytes and the committed memory snapshot.
        let corruptURL = directory.appendingPathComponent("corrupt.json")
        let corruptBytes = Data("{not-json".utf8)
        try corruptBytes.write(to: corruptURL)
        let corrupt = SyncRepository(fileURL: corruptURL)
        expect(corrupt.loadError != nil, "Corruption must block, never become a fresh store.")
        do { _ = try corrupt.checkpoints(); fatalError("Corrupt checkpoints must throw") } catch {}
        do { try corrupt.setSleepCheckpoint(date(999)); fatalError("Corrupt store must reject writes") } catch {}
        try expect(try Data(contentsOf: corruptURL) == corruptBytes, "Corrupt original must be preserved.")
        do { try corrupt.ensureUsable(); fatalError("A corrupt store must stay blocked on retry") } catch {}

        // A store that was unreadable at launch (device locked) becomes usable once readable again.
        if getuid() == 0 {
            print("Skipping locked-store reload check: running as root ignores file permissions.")
        } else {
            let lockedURL = directory.appendingPathComponent("locked.json")
            try SyncRepository(fileURL: lockedURL).setSleepCheckpoint(date(321))
            let lockedOriginal = try SyncRepository(fileURL: lockedURL).checkpoints()
            let lockedBytes = try Data(contentsOf: lockedURL)
            try FileManager.default.setAttributes([.posixPermissions: 0o000], ofItemAtPath: lockedURL.path)
            let locked = SyncRepository(fileURL: lockedURL)
            do { try locked.ensureUsable(); fatalError("An unreadable store must block") } catch {}
            do { try locked.setSleepCheckpoint(date(999)); fatalError("An unreadable store must reject writes") } catch {}
            try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: lockedURL.path)
            try expect(try Data(contentsOf: lockedURL) == lockedBytes, "A locked store is never overwritten.")
            do { try locked.setHeartRateCheckpoint(date(888), resolution: 60); fatalError("save must not reload over a pending write") } catch {}
            try locked.ensureUsable()
            try expect(try locked.checkpoints() == lockedOriginal, "Reload after unlock restores the stored checkpoints.")
            try locked.setHeartRateCheckpoint(date(654), resolution: 60)
            let lockedReload = try SyncRepository(fileURL: lockedURL).checkpoints()
            expect(lockedReload.lastSleepQueryEnd == date(321) && lockedReload.lastHeartRateEnd == date(654),
                   "Writes after reload keep old data and add new progress.")
        }

        let failureURL = directory.appendingPathComponent("failure.json")
        let originalRepo = SyncRepository(fileURL: failureURL)
        try originalRepo.setSleepCheckpoint(date(123))
        let originalBytes = try Data(contentsOf: failureURL)
        let failing = SyncRepository(fileURL: failureURL, writeData: { _, _ in throw CocoaError(.fileWriteNoPermission) })
        do { try failing.setSleepCheckpoint(date(999)); fatalError("Injected write should fail") } catch {}
        try expect(try failing.checkpoints().lastSleepQueryEnd == date(123), "Failed write must roll back memory.")
        try expect(try Data(contentsOf: failureURL) == originalBytes, "Failed write must preserve disk.")
        try failing.appendEvent(runID: nil, level: "info", category: "failed", message: "must not publish")
        do { try failing.setSleepCheckpoint(date(999)); fatalError("Injected write should fail") } catch {}
        expect(failing.diagnostics().recentEvents.isEmpty, "Failed save must roll back unsaved events.")

        let batchURL = directory.appendingPathComponent("batch.json")
        var writeCount = 0
        let batched = SyncRepository(fileURL: batchURL, writeData: { data, url in
            writeCount += 1
            try data.write(to: url, options: [.atomic])
        })
        for index in 0..<100 {
            try batched.appendEvent(runID: nil, level: "info", category: "batch", message: "event \(index)")
        }
        expect(writeCount == 0, "Appending events must not write the store.")
        try batched.setSleepCheckpoint(date(321))
        expect(writeCount == 1, "The next save must persist pending events in one write.")
        let batchedReloaded = SyncRepository(fileURL: batchURL)
        expect(batchedReloaded.diagnostics().recentEvents.filter { $0.category == "batch" }.count == 100, "Pending events must persist with the next save.")

        var legacyObject = try JSONSerialization.jsonObject(with: originalBytes) as! [String: Any]
        legacyObject.removeValue(forKey: "schemaVersion"); legacyObject.removeValue(forKey: "recovery")
        let migrationFixtureURL = directory.appendingPathComponent("legacy.json")
        let legacyBytes = try JSONSerialization.data(withJSONObject: legacyObject)
        try legacyBytes.write(to: migrationFixtureURL)
        let migrated = SyncRepository(fileURL: migrationFixtureURL)
        try expect(try migrated.checkpoints().lastSleepQueryEnd == date(123), "Migration preserves old checkpoints.")
        try expect(try !migrated.recoveryState().enabled, "Migration defaults HRV to disabled.")
        try migrated.setHeartRateCheckpoint(date(456), resolution: 60)
        try expect(try Data(contentsOf: migrationFixtureURL.appendingPathExtension("v1-backup")) == legacyBytes, "Migration backup is exact.")
        let migratedObject = try JSONSerialization.jsonObject(with: Data(contentsOf: migrationFixtureURL)) as! [String: Any]
        expect(migratedObject["schemaVersion"] as? Int == 2, "Migrated schema must be v2.")
        expect(migrated.requiresManualAccountBinding, "Legacy checkpoints require manual ownership confirmation.")
        let beforeBinding = try Data(contentsOf: migrationFixtureURL)
        do { try migrated.validateAccount("account-A"); fatalError("Validation cannot silently bind legacy progress") }
        catch let error as SyncRepositoryError { guard case .accountBindingRequired = error else { throw error } }
        try expect(try Data(contentsOf: migrationFixtureURL) == beforeBinding, "Rejected legacy validation leaves disk unchanged.")
        try migrated.bindAccountManually("account-A")
        expect(!migrated.requiresManualAccountBinding, "Explicit binding resolves the migration prompt.")
        do { try migrated.validateAccount("account-B"); fatalError("Account mismatch must throw") } catch {}
        var recoveryState = try migrated.recoveryState()
        recoveryState.accountKey = "account-A"
        recoveryState.pendingItems["old"] = RecoveryPendingItem(cycleID: "old", firstDetectedAt: date(0), reason: "access")
        try migrated.commitRecoveryState(recoveryState)
        let migratedReload = SyncRepository(fileURL: migrationFixtureURL)
        try migratedReload.validateAccount("account-A")
        expect(!migratedReload.requiresManualAccountBinding, "Account binding survives restart.")
        try expect(try migratedReload.recoveryState().pendingItems.count == 1, "Historical pending state survives restart.")

        let newStore = SyncRepository(fileURL: directory.appendingPathComponent("new-account.json"))
        try newStore.validateAccount("new-account")
        do { try newStore.validateAccount("other-account"); fatalError("New stores must persist the first authenticated identity") }
        catch let error as RecoverySyncError { expect(error == .accountMismatch, "New-store identity is persisted.") }
        do { try failing.bindAccountManually("failed-account"); fatalError("Binding write failure must throw") } catch {}
        expect(failing.requiresManualAccountBinding, "Failed binding must preserve unbound memory state.")
        try expect(try Data(contentsOf: failureURL) == originalBytes, "Failed binding retains original disk bytes.")
        let futureURL = directory.appendingPathComponent("future.json")
        try Data("{\"schemaVersion\":99}".utf8).write(to: futureURL)
        let future = SyncRepository(fileURL: futureURL)
        expect(future.loadError != nil, "Unknown schemas must block synchronization.")
        let setupURL = directory.appendingPathComponent("setup-atomic.json")
        let freshSetup = SyncRepository(fileURL: setupURL)
        var setupWrites = 0
        let atomic = SyncRepository(fileURL: setupURL, writeData: { data, target in
            setupWrites += 1; try data.write(to: target, options: .atomic)
        })
        var enabled = RecoverySyncState(); enabled.enabled = true; enabled.configured = true
        enabled.accountKey = "synthetic-setup-account"; enabled.historyStartDate = date(100)
        try atomic.saveSyncSetup(recovery: enabled, accountKey: enabled.accountKey)
        expect(setupWrites == 1, "Account, HRV and setup marker must use a single snapshot write.")
        let committedBytes = try Data(contentsOf: setupURL)
        let setupReload = SyncRepository(fileURL: setupURL)
        try expect(try setupReload.recoveryState() == enabled && setupReload.hasCompletedSyncSetup, "Atomic setup survives reload.")
        let brokenSetup = SyncRepository(fileURL: setupURL, writeData: { _, _ in throw SyncRepositoryError.storeWriteFailed })
        var disabled = enabled; disabled.enabled = false
        do { try brokenSetup.saveSyncSetup(recovery: disabled); fatalError("Setup write must fail") } catch {}
        try expect(try brokenSetup.recoveryState() == enabled && Data(contentsOf: setupURL) == committedBytes, "Setup failure retains HRV, marker and bytes.")
        expect(!freshSetup.hasCompletedSyncSetup, "A token/account alone is not configured progress.")
        let unreadableWAL = setupURL.appendingPathExtension("recovery-wal")
        try Data("{}".utf8).write(to: unreadableWAL)
        try FileManager.default.setAttributes([.posixPermissions: 0o000], ofItemAtPath: unreadableWAL.path)
        defer { try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: unreadableWAL.path) }
        let protectedJournal = SyncRepository(fileURL: setupURL)
        expect(protectedJournal.loadError != nil, "An unreadable WAL must block a readable main store rather than silently drop pending operations.")
        do { try protectedJournal.completeSyncSetup(); fatalError("Protected journal must block setup writes") } catch {}
        try expect(try Data(contentsOf: setupURL) == committedBytes, "An unreadable WAL never replaces the main store.")

        let deferredURL = directory.appendingPathComponent("deferred-store.json", isDirectory: false)
        let deferredRepository = SyncRepository(fileURL: deferredURL)
        try deferredRepository.narrowDeferredWindow(to: date(50), for: "sleep")
        try expect(try deferredRepository.deferredWindow(for: "sleep") == nil, "Narrowing a missing deferral must not create one.")
        try deferredRepository.setDeferredWindow(TimeRange(start: date(10), end: date(100)), for: "sleep")
        try deferredRepository.narrowDeferredWindow(to: date(200), for: "sleep")
        try expect(try deferredRepository.deferredWindow(for: "sleep") == TimeRange(start: date(10), end: date(100)), "Narrowing past the end must not widen a deferral.")
        try deferredRepository.narrowDeferredWindow(to: date(50), for: "sleep")
        try expect(try SyncRepository(fileURL: deferredURL).deferredWindow(for: "sleep") == TimeRange(start: date(10), end: date(50)), "A narrowed deferral keeps its start and survives reload.")
        try deferredRepository.narrowDeferredWindow(to: date(10), for: "sleep")
        try expect(try SyncRepository(fileURL: deferredURL).deferredWindow(for: "sleep") == nil, "Narrowing to the start removes the deferral.")
        print("SyncRepository smoke check passed (migration, corruption, disk rollback, account separation)")
    }

    private static func date(_ seconds: TimeInterval) -> Date {
        Date(timeIntervalSince1970: seconds)
    }

    private static func sleepSession(id: String, start: Date) throws -> SleepSession {
        try SleepNormalizer.normalize(
            SleepSession(
                whoopSleepID: id,
                sourceUpdatedAt: start.addingTimeInterval(600),
                start: start,
                end: start.addingTimeInterval(120),
                timezoneOffsetSeconds: nil,
                isNap: false,
                stages: [
                    SleepStageInterval(start: start, end: start.addingTimeInterval(60), stage: .core),
                    SleepStageInterval(start: start.addingTimeInterval(60), end: start.addingTimeInterval(120), stage: .rem)
                ]
            )
        )
    }

    private static func expect(_ condition: @autoclosure () throws -> Bool, _ message: String) rethrows {
        guard try condition() else {
            fatalError(message)
        }
    }
}
