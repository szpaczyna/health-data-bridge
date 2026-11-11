import AppIntents
import Foundation
import WHOOPHealthSyncCore

@main
struct AppIntentsSmokeCheck {
    @MainActor static func main() throws {
        var summary = SyncSummary()
        summary.stagesWritten = 4
        summary.heartRateWritten = 120

        let text = SynchronizeWhoopIntent.resultText(summary)
        precondition(text.contains("Sync completed:"))
        precondition(text.contains("stages=4"))
        precondition(text.contains("HR=120"))
        precondition(WHOOPHealthSyncShortcuts.appShortcuts.count == 1)

        summary.errors = ["fixture"]
        let partialText = SynchronizeWhoopIntent.resultText(summary)
        precondition(partialText.contains("Sync completed with issues:"))

        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("intent-setup-\(UUID())")
        defer { try? FileManager.default.removeItem(at: directory) }
        let repository = SyncRepository(fileURL: directory.appendingPathComponent("sync-store.json"))
        try repository.bindAccountManually("synthetic-intent-account")
        do { try LiveSyncRuntime.validateAutomatedSetup(repository: repository); fatalError("Token/account alone must not allow unattended setup") }
        catch AutomatedSyncError.initialManualSyncRequired {}
        try repository.completeSyncSetup()
        do { try LiveSyncRuntime.validateAutomatedSetup(repository: repository); fatalError("Saved configuration without safe first sync must require the app") }
        catch AutomatedSyncError.initialManualSyncRequired {}
        let checkpoint = Date(timeIntervalSince1970: 1_700_000_000)
        try repository.setSleepCheckpoint(checkpoint); try repository.setHeartRateCheckpoint(checkpoint, resolution: 60)
        let bytes = try Data(contentsOf: directory.appendingPathComponent("sync-store.json"))
        try LiveSyncRuntime.validateAutomatedSetup(repository: repository)
        let after = try Data(contentsOf: directory.appendingPathComponent("sync-store.json"))
        precondition(after == bytes)
        let existing = SyncRepository(fileURL: directory.appendingPathComponent("legacy-shortcut.json"))
        try existing.bindAccountManually("synthetic-intent-account")
        try existing.setSleepCheckpoint(checkpoint); try existing.setHeartRateCheckpoint(checkpoint, resolution: 60)
        try LiveSyncRuntime.validateAutomatedSetup(repository: existing) // No new setup marker required.
        summary.sleepResult = .noData; summary.heartRateResult = .existing
        let differentiated = SynchronizeWhoopIntent.resultText(summary)
        precondition(differentiated.contains("sleep: No data received"))
        precondition(differentiated.contains("HR: Data already existed"))

        print("App Intents smoke check passed")
    }
}
