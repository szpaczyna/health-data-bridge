#if DEBUG

import SwiftUI
import WHOOPHealthSyncCore

@MainActor
enum PreviewFixtures {
    static func makeViewModel(
        authStatus: AuthStatus,
        setupCompleted: Bool,
        recoveryConfigured: Bool = false,
        accountBindingRequired: Bool = false,
        summary: SyncSummary? = nil,
        errors: [String] = [],
        lastRunStatus: String? = "success"
    ) -> SyncViewModel {
        let now = Date()
        let repository = makeRepository(
            setupCompleted: setupCompleted,
            recoveryConfigured: recoveryConfigured,
            accountBindingRequired: accountBindingRequired,
            summary: summary,
            lastRunStatus: lastRunStatus,
            now: now
        )
        let viewModel = SyncViewModel(repository: repository, initialAuthStatus: authStatus)
        viewModel.configure()
        if let summary {
            viewModel.lastSummary = summary
        }
        if !errors.isEmpty {
            viewModel.errors = errors
        }
        return viewModel
    }

    static func makeSummary(recoveryConfigured: Bool) -> SyncSummary {
        let now = Date()
        var summary = SyncSummary()
        summary.sleepResult = .updated
        summary.heartRateResult = .updated
        summary.sleepsWritten = 2
        summary.sleepsUnchanged = 1
        summary.stagesWritten = 8
        summary.heartRateWritten = 42
        summary.heartRateSkipped = 5
        summary.effectiveHeartRateResolution = 6
        summary.sleepQueryWindowStart = now.addingTimeInterval(-7 * 86400)
        summary.sleepQueryWindowEnd = now
        summary.heartRateWindowStart = now.addingTimeInterval(-24 * 3600)
        summary.heartRateWindowEnd = now
        summary.elapsedSeconds = 4.2
        if recoveryConfigured {
            summary.recovery.status = .historyLimited
            summary.recovery.written = 3
            summary.recovery.pagesConfirmed = 12
        }
        return summary
    }

    private static func makeRepository(
        setupCompleted: Bool,
        recoveryConfigured: Bool,
        accountBindingRequired: Bool,
        summary: SyncSummary?,
        lastRunStatus: String?,
        now: Date
    ) -> SyncRepository {
        let repository = SyncRepository(
            fileURL: FileManager.default.temporaryDirectory
                .appendingPathComponent("whoop-preview-\(UUID().uuidString).json"),
            writeData: { _, _ in }
        )
        guard setupCompleted else { return repository }

        try? repository.completeSyncSetup()
        try? repository.setSleepCheckpoint(now.addingTimeInterval(-3600))
        try? repository.setHeartRateCheckpoint(now.addingTimeInterval(-3600), resolution: 6)

        if recoveryConfigured {
            var state = RecoverySyncState()
            state.enabled = true
            state.configured = true
            state.historyStartDate = now.addingTimeInterval(-30 * 86400)
            state.initialImportCutoff = now.addingTimeInterval(-7 * 86400)
            state.initialEnumerationComplete = true
            state.historicalPagesConfirmed = 12
            state.lastDiscoveryEnd = now.addingTimeInterval(-86400)
            state.userConfirmedFullReadAccess = true
            state.historyScopeLimited = true
            try? repository.saveSyncSetup(recovery: state)
        }

        if let summary, let lastRunStatus {
            let runID = try? repository.createRejectedRun(startedAt: now.addingTimeInterval(-3600))
            if let runID {
                try? repository.finishRun(runID, summary: summary, status: lastRunStatus)
            }
        }

        if !accountBindingRequired {
            try? repository.bindAccountManually("preview-account")
        }
        return repository
    }
}

private struct DashboardPreview: View {
    let viewModel: SyncViewModel
    @State private var presentedSheet: SyncSheet?

    var body: some View {
        SyncDashboardView(viewModel: viewModel, presentedSheet: $presentedSheet)
    }
}

private struct OptionsPreview: View {
    let viewModel: SyncViewModel
    @State private var appLanguage: AppLanguage = .system
    @State private var appearance: Appearance = .system
    @State private var presentedSheet: SyncSheet?

    var body: some View {
        OptionsView(
            viewModel: viewModel,
            appLanguage: $appLanguage,
            appearance: $appearance,
            presentedSheet: $presentedSheet
        )
    }
}

#Preview("Dashboard - synced") {
    NavigationStack {
        DashboardPreview(
            viewModel: PreviewFixtures.makeViewModel(
                authStatus: .authenticated(email: "preview@example.com"),
                setupCompleted: true,
                recoveryConfigured: true,
                summary: PreviewFixtures.makeSummary(recoveryConfigured: true)
            )
        )
    }
}

#Preview("Dashboard - needs setup") {
    NavigationStack {
        DashboardPreview(
            viewModel: PreviewFixtures.makeViewModel(
                authStatus: .authenticated(email: "preview@example.com"),
                setupCompleted: false,
                lastRunStatus: nil
            )
        )
    }
}

#Preview("Dashboard - reconnect") {
    NavigationStack {
        DashboardPreview(
            viewModel: PreviewFixtures.makeViewModel(
                authStatus: .reconnectRequired(reason: "Preview session expired."),
                setupCompleted: true,
                recoveryConfigured: true,
                errors: ["Preview session expired."],
                lastRunStatus: "failed"
            )
        )
    }
}

#Preview("Options - configured") {
    NavigationStack {
        OptionsPreview(
            viewModel: PreviewFixtures.makeViewModel(
                authStatus: .authenticated(email: "preview@example.com"),
                setupCompleted: true,
                recoveryConfigured: true,
                summary: PreviewFixtures.makeSummary(recoveryConfigured: true)
            )
        )
    }
}

#Preview("Options - account binding") {
    NavigationStack {
        OptionsPreview(
            viewModel: PreviewFixtures.makeViewModel(
                authStatus: .authenticated(email: "preview@example.com"),
                setupCompleted: true,
                recoveryConfigured: true,
                accountBindingRequired: true,
                summary: PreviewFixtures.makeSummary(recoveryConfigured: true)
            )
        )
    }
}

#Preview("Authentication - sign in") {
    AuthenticationSheet(
        viewModel: PreviewFixtures.makeViewModel(
            authStatus: .disconnected,
            setupCompleted: false,
            lastRunStatus: nil
        )
    )
}

#Preview("Authentication - MFA") {
    AuthenticationSheet(
        viewModel: PreviewFixtures.makeViewModel(
            authStatus: .mfaRequired(challengeName: "SMS_MFA", destination: "+1 ••• ••• 1234"),
            setupCompleted: false,
            lastRunStatus: nil
        )
    )
}

#Preview("Authentication - reconnect") {
    AuthenticationSheet(
        viewModel: PreviewFixtures.makeViewModel(
            authStatus: .reconnectRequired(reason: "Preview session expired."),
            setupCompleted: true,
            errors: ["Preview session expired."],
            lastRunStatus: "failed"
        )
    )
}

#Preview("App root") {
    AppRootView(
        viewModel: PreviewFixtures.makeViewModel(
            authStatus: .authenticated(email: "preview@example.com"),
            setupCompleted: true,
            recoveryConfigured: true,
            summary: PreviewFixtures.makeSummary(recoveryConfigured: true)
        )
    )
}

#endif
