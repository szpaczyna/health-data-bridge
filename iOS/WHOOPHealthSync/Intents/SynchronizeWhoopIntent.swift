import AppIntents
import Foundation
import WHOOPHealthSyncCore

struct SynchronizeWhoopIntent: AppIntent {
    static let title: LocalizedStringResource = "Sync WHOOP"
    static let description = IntentDescription(
        "Fills heart-rate and sleep-stage gaps in Apple Health using WHOOP."
    )
    static let openAppWhenRun = false

    @MainActor
    func perform() async throws -> some IntentResult & ProvidesDialog & ReturnsValue<String> {
        do {
            let summary = try await LiveSyncRuntime.shared.synchronizeFromAutomation()
            let result = Self.resultText(summary)

            let dialog = summary.errors.isEmpty
                ? AppLocalization.string("Sync completed.")
                : AppLocalization.string("Sync completed with issues.")
            return .result(value: result, dialog: IntentDialog(stringLiteral: dialog))
        } catch {
            throw ShortcutSyncError.failed(Self.message(error))
        }
    }

    static func resultText(_ summary: SyncSummary) -> String {
        let headline = summary.errors.isEmpty
            ? AppLocalization.string("Sync completed")
            : AppLocalization.string("Sync completed with issues")
        let sleep = dataStatus(summary.sleepResult)
        let heartRate = dataStatus(summary.heartRateResult)
        let recovery = recoveryStatus(summary.recovery.status)
        let details = AppLocalization.string("stages=\(summary.stagesWritten), sleep: \(sleep), HR=\(summary.heartRateWritten), HR: \(heartRate), HRV=\(summary.recovery.written), skipped HRV=\(summary.recovery.skippedExternal), HRV: \(recovery), issues=\(summary.errors.count)")
        return "\(headline): \(details)"
    }

    static func dataStatus(_ status: SyncDataResult) -> String {
        switch status {
        case .notAttempted: return AppLocalization.string("Not checked")
        case .noData: return AppLocalization.string("No data received")
        case .existing: return AppLocalization.string("Data already existed")
        case .updated: return AppLocalization.string("Samples added or updated")
        case .pendingAccess: return AppLocalization.string("Pending access check")
        case .failed: return AppLocalization.string("Could not finish; retry required")
        }
    }

    static func recoveryStatus(_ status: RecoveryFlowStatus) -> String {
        switch status {
        case .disabled: return AppLocalization.string("disabled")
        case .configurationPending: return AppLocalization.string("configuration pending")
        case .requiresIOS27: return AppLocalization.string("requires iOS 27")
        case .completed: return AppLocalization.string("completed")
        default: return AppLocalization.string("pending/with issues")
        }
    }

    private static func message(_ error: Error) -> String {
        let rawMessage: String
        if let localized = error as? LocalizedError, let description = localized.errorDescription {
            rawMessage = description
        } else {
            rawMessage = error.localizedDescription
        }
        return SensitiveTextSanitizer.redact(rawMessage)
    }
}

private enum ShortcutSyncError: Error, LocalizedError {
    case failed(String)

    var errorDescription: String? {
        switch self {
        case let .failed(message):
            return message
        }
    }
}

struct WHOOPHealthSyncShortcuts: AppShortcutsProvider {
    static var appShortcuts: [AppShortcut] {
        AppShortcut(
            intent: SynchronizeWhoopIntent(),
            phrases: [
                "Sync \(.applicationName)",
                "Update Apple Health with \(.applicationName)",
                "Sincronizar \(.applicationName)",
                "Actualizar Apple Health con \(.applicationName)",
                "Synchronizuj \(.applicationName)"
            ],
            shortTitle: "Sync WHOOP",
            systemImageName: "arrow.triangle.2.circlepath.heart"
        )
    }
}
