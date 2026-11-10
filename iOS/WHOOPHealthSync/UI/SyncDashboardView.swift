import AppIntents
import SwiftUI

struct SyncDashboardView: View {
    @ObservedObject var viewModel: SyncViewModel
    @Binding var presentedSheet: SyncSheet?
    @Environment(\.locale) private var locale
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @AppStorage("shortcutsIntroductionDismissed") private var shortcutsIntroductionDismissed = false

    var body: some View {
        List {
            Section {
                VStack(alignment: .leading, spacing: 14) {
                    Label {
                        Text(syncHeadline)
                    } icon: {
                        Image(systemName: syncStatusSystemImage)
                    }
                    .font(.headline)
                    .foregroundStyle(isAuthenticated ? .primary : .secondary)

                    Text(syncDescription)
                        .font(.subheadline)
                        .foregroundStyle(.secondary)

                    Button {
                        if viewModel.needsInitialSetup {
                            presentedSheet = .configuration
                        } else if isAuthenticated {
                            Task {
                                await viewModel.synchronize()
                            }
                        } else {
                            presentedSheet = .authentication
                        }
                    } label: {
                        HStack(spacing: 10) {
                            if viewModel.isSyncing {
                                ProgressView()
                                    .tint(.white)
                            } else {
                                Image(systemName: "arrow.triangle.2.circlepath")
                            }
                            Text(primaryButtonTitle)
                                .fontWeight(.semibold)
                        }
                        .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.large)
                    .disabled(viewModel.isSyncing || !viewModel.repositoryAvailable || viewModel.isConfiguringRecovery)
                    .accessibilityIdentifier("sync.primary")
                    .accessibilityHint(
                        isAuthenticated
                            ? Text("Fills gaps detected in Apple Health since the last sync")
                            : Text("Opens the WHOOP sign-in flow")
                    )
                }
                .padding(.vertical, 8)
            }

            if let summary = viewModel.lastSummary {
                Section("Summary") {
                    LabeledContent("Stages written", value: "\(summary.stagesWritten)")
                    LabeledContent { Text(LocalizedStringKey(summary.sleepResult.rawValue)) } label: { Text("Sleep") }
                    LabeledContent("Already existing sleep", value: "\(summary.sleepsUnchanged)")
                    LabeledContent("Heart-rate samples written", value: "\(summary.heartRateWritten)")
                    LabeledContent { Text(LocalizedStringKey(summary.heartRateResult.rawValue)) } label: { Text("Heart rate") }
                    LabeledContent("Already existing heart rate", value: "\(summary.heartRateSkipped)")
                    LabeledContent("Recovery HRV written", value: "\(summary.recovery.written)")
                    Text(LocalizedStringKey(viewModel.recoveryResultKey(summary.recovery)))
                    LabeledContent("Already existing HRV", value: "\(summary.recovery.unchanged + summary.recovery.skippedExternal)")
                    LabeledContent("Pending HRV", value: "\(summary.recovery.pending)")
                }
            }

            if !shortcutsIntroductionDismissed {
                Section {
                    VStack(alignment: .leading, spacing: 12) {
                        HStack(alignment: .top, spacing: 12) {
                            Image(systemName: "wand.and.stars")
                                .font(.title3)
                                .foregroundStyle(.tint)
                                .accessibilityHidden(true)

                            VStack(alignment: .leading, spacing: 5) {
                                Text("Available in Shortcuts")
                                    .font(.headline)
                                Text("Run the same sync from Siri or a personal automation. Your account and HealthKit must first be authorized in this app.")
                                    .font(.footnote)
                                    .foregroundStyle(.secondary)
                            }

                            Spacer(minLength: 4)

                            Button {
                                withAnimation {
                                    shortcutsIntroductionDismissed = true
                                }
                            } label: {
                                Image(systemName: "xmark.circle.fill")
                                    .font(.title3)
                                    .foregroundStyle(.tertiary)
                            }
                            .buttonStyle(.plain)
                            .accessibilityLabel("Dismiss Shortcuts information")
                        }

                        #if os(iOS)
                        ShortcutsLink()
                        #else
                        Text("Open Shortcuts on your iPhone to add the Sync WHOOP action.")
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                        #endif
                    }
                    .padding(.vertical, 4)
                }
            }

            Section("Last synced data") {
                lastRunRow
                syncedDataRow(
                    title: "Sleep",
                    systemImage: "moon.zzz.fill",
                    value: dateValue(viewModel.diagnostics.lastSleepCheckpoint)
                )
                syncedDataRow(
                    title: "Heart rate",
                    systemImage: "heart.fill",
                    value: dateValue(viewModel.diagnostics.lastHeartRateCheckpoint)
                )
                adaptiveRow {
                    Label("Recovery HRV", systemImage: "waveform.path.ecg")
                    if !dynamicTypeSize.isAccessibilitySize { Spacer() }
                    VStack(alignment: dynamicTypeSize.isAccessibilitySize ? .leading : .trailing, spacing: 3) {
                        Text(LocalizedStringKey(viewModel.recoveryStatusKey))
                            .accessibilityIdentifier("recovery.dashboard.status")
                        if let date = viewModel.recoveryState.lastDiscoveryEnd {
                            Text(dateValue(date)).font(.caption)
                        }
                    }
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(dynamicTypeSize.isAccessibilitySize ? .leading : .trailing)
                }
            }

            if !viewModel.errors.isEmpty {
                Section("Errors") {
                    Text("Pending access check or retry").foregroundStyle(.red)
                    NavigationLink("Activity and diagnostics") { SyncActivityView(viewModel: viewModel) }
                }
            }

        }
        .whoopDashboardListStyle()
        .navigationTitle("HealthDataBridge")
    }

    private var isAuthenticated: Bool {
        if case .authenticated = viewModel.authStatus {
            return true
        }
        return false
    }

    private var syncHeadline: LocalizedStringKey {
        if viewModel.isSyncing {
            return "Sync in progress"
        }
        if viewModel.needsInitialSetup { return "Set up your data" }
        if !viewModel.repositoryAvailable { return "Local data unavailable" }
        if !isAuthenticated && viewModel.setupCompleted { return "Reconnect WHOOP; saved progress retained" }
        if let summary = viewModel.lastSummary { return summary.hasIncompleteResults ? "Partial result; review pending data" : "Sync finished" }
        if !viewModel.errors.isEmpty || viewModel.diagnostics.lastRunStatus == "failed" || viewModel.diagnostics.lastRunStatus == "partial" { return "Pending access check or retry" }
        if viewModel.setupCompleted && viewModel.diagnostics.lastRunFinishedAt == nil &&
            viewModel.diagnostics.lastSleepCheckpoint == nil && viewModel.diagnostics.lastHeartRateCheckpoint == nil { return "Configuration saved; first sync pending" }
        return isAuthenticated ? "Ready to sync" : "Connect WHOOP to get started"
    }

    private var syncDescription: LocalizedStringKey {
        if isAuthenticated {
            return "Sync sleep, heart rate and authorized HRV together. Only missing data is added; other sources are preserved."
        }
        if viewModel.setupCompleted { return "Your account, imported data and saved progress are retained. This does not restart history." }
        return "Complete your sleep, heart rate and, when available, recovery HRV data in Health."
    }

    private var syncStatusSystemImage: String {
        if viewModel.isSyncing {
            return "arrow.triangle.2.circlepath"
        }
        return isAuthenticated ? "heart.text.square.fill" : "lock.circle"
    }

    private var primaryButtonTitle: LocalizedStringKey {
        if viewModel.isSyncing {
            return "Syncing…"
        }
        if isAuthenticated {
            if viewModel.needsInitialSetup { return "Set up sync" }
            return "Sync now"
        }
        switch viewModel.authStatus {
        case .reconnectRequired:
            return "Reconnect"
        case .disconnected where viewModel.setupCompleted:
            return "Reconnect"
        case .authenticated, .disconnected:
            return "Connect WHOOP"
        }
    }

    private var lastRunRow: some View {
        adaptiveRow {
            Label("Last run", systemImage: "clock.fill")
            if !dynamicTypeSize.isAccessibilitySize { Spacer() }
            VStack(alignment: dynamicTypeSize.isAccessibilitySize ? .leading : .trailing, spacing: 2) {
                if let date = viewModel.diagnostics.lastRunFinishedAt ?? viewModel.diagnostics.lastRunStartedAt {
                    Text(dateValue(date))
                        .monospacedDigit()
                    Text(lastRunStatus)
                        .font(.caption)
                        .foregroundStyle(lastRunStatusColor)
                } else {
                    Text("Never")
                        .foregroundStyle(.secondary)
                }
            }
            .multilineTextAlignment(dynamicTypeSize.isAccessibilitySize ? .leading : .trailing)
        }
    }

    private var lastRunStatus: LocalizedStringKey {
        switch viewModel.diagnostics.lastRunStatus {
        case "success":
            return "Completed"
        case "partial":
            return "Completed with issues"
        case "failed":
            return "Failed"
        case "running":
            return "In progress"
        default:
            return "Unknown"
        }
    }

    private var lastRunStatusColor: Color {
        switch viewModel.diagnostics.lastRunStatus {
        case "success":
            return .green
        case "partial":
            return .orange
        case "failed":
            return .red
        default:
            return .secondary
        }
    }

    private func syncedDataRow(title: LocalizedStringKey, systemImage: String, value: String) -> some View {
        adaptiveRow {
            Label {
                Text(title)
            } icon: {
                Image(systemName: systemImage)
            }
            if !dynamicTypeSize.isAccessibilitySize { Spacer() }
            Text(value)
                .multilineTextAlignment(dynamicTypeSize.isAccessibilitySize ? .leading : .trailing)
                .monospacedDigit()
                .foregroundStyle(.secondary)
        }
    }

    @ViewBuilder
    private func adaptiveRow<Content: View>(@ViewBuilder content: () -> Content) -> some View {
        if dynamicTypeSize.isAccessibilitySize {
            VStack(alignment: .leading, spacing: 8, content: content)
        } else {
            HStack(spacing: 12, content: content)
        }
    }

    private func dateValue(_ date: Date?) -> String {
        guard let date else {
            return "-"
        }
        let formatter = DateFormatter()
        formatter.locale = locale
        formatter.dateStyle = .medium
        formatter.timeStyle = .short
        return formatter.string(from: date)
    }
}

extension View {
    @ViewBuilder
    func whoopDashboardListStyle() -> some View {
        #if os(iOS)
        self.listStyle(.insetGrouped)
        #else
        self.listStyle(.inset)
        #endif
    }
}
