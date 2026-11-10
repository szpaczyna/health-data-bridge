import SwiftUI

enum AppLanguage: String, CaseIterable, Identifiable {
    case system
    case english
    case spanish
    case polish

    var id: String { rawValue }

    var title: LocalizedStringKey {
        switch self {
        case .system:
            return "Automatic"
        case .english:
            return "English"
        case .spanish:
            return "Spanish"
        case .polish:
            return "Polish"
        }
    }

    var locale: Locale {
        switch self {
        case .system:
            let preferredLanguage = Locale.preferredLanguages.first?.lowercased() ?? "en"
            if preferredLanguage.hasPrefix("es") { return Locale(identifier: "es") }
            if preferredLanguage.hasPrefix("pl") { return Locale(identifier: "pl") }
            return Locale(identifier: "en")
        case .english:
            return Locale(identifier: "en")
        case .spanish:
            return Locale(identifier: "es")
        case .polish:
            return Locale(identifier: "pl")
        }
    }
}

private enum AppTab: Hashable {
    case sync
    case options
}

enum SyncSheet: String, Identifiable {
    case authentication, configuration, history
    var id: String { rawValue }
}

struct AppRootView: View {
    @StateObject private var viewModel: SyncViewModel
    @State private var selectedTab: AppTab = .sync
    @State private var presentedSheet: SyncSheet?
    @State private var configureAfterLogin = false
    @State private var showsDisconnectConfirmation = false
    @AppStorage("appLanguage") private var appLanguage: AppLanguage = .system
    @AppStorage("appearance") private var appearance: Appearance = .system

    init() {
        _viewModel = StateObject(wrappedValue: SyncViewModel())
    }

    init(viewModel: SyncViewModel) {
        _viewModel = StateObject(wrappedValue: viewModel)
    }

    var body: some View {
        TabView(selection: $selectedTab) {
            NavigationStack {
                SyncDashboardView(
                    viewModel: viewModel,
                    presentedSheet: $presentedSheet
                )
                .toolbar {
                    accountToolbar
                }
            }
            .tabItem {
                Label("Sync", systemImage: "arrow.triangle.2.circlepath")
            }
            .tag(AppTab.sync)

            NavigationStack {
                OptionsView(viewModel: viewModel, appLanguage: $appLanguage, appearance: $appearance, presentedSheet: $presentedSheet)
                    .toolbar {
                        accountToolbar
                    }
            }
            .tabItem {
                Label("Options", systemImage: "gearshape.fill")
            }
            .tag(AppTab.options)
        }
        .preferredColorScheme(appearance.colorScheme)
        .sheet(item: $presentedSheet, onDismiss: {
            if configureAfterLogin {
                configureAfterLogin = false
                presentedSheet = .configuration
            }
        }) { destination in
            switch destination {
            case .authentication:
                AuthenticationSheet(viewModel: viewModel, onConnected: {
                    configureAfterLogin = viewModel.needsInitialSetup
                })
            case .configuration: SyncSetupView(viewModel: viewModel)
            case .history: HistoryImportView(viewModel: viewModel)
            }
        }
        .confirmationDialog(
            "Disconnect WHOOP?",
            isPresented: $showsDisconnectConfirmation,
            titleVisibility: .visible
        ) {
            Button("Disconnect", role: .destructive) {
                viewModel.disconnect()
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("The saved session will be removed from this iPhone. Data already written to Apple Health will not be deleted.")
        }
        .environment(\.locale, appLanguage.locale)
        .onAppear {
            viewModel.configure()
        }
    }

    @ToolbarContentBuilder
    private var accountToolbar: some ToolbarContent {
        ToolbarItem(placement: .primaryAction) {
            Menu {
                if case let .authenticated(email) = viewModel.authStatus {
                    Button {} label: {
                        Label(email, systemImage: "person.crop.circle.fill")
                    }
                    .disabled(true)

                    Button {
                        presentedSheet = .authentication
                    } label: {
                        Label("Reconnect", systemImage: "arrow.clockwise")
                    }
                    .disabled(viewModel.isSyncing || viewModel.isBindingAccount)

                    Divider()

                    Button(role: .destructive) {
                        showsDisconnectConfirmation = true
                    } label: {
                        Label("Disconnect WHOOP", systemImage: "rectangle.portrait.and.arrow.right")
                    }
                    .disabled(viewModel.isSyncing || viewModel.isBindingAccount)
                } else {
                    Button {
                        presentedSheet = .authentication
                    } label: {
                        Label(accountActionTitle, systemImage: "person.crop.circle.badge.plus")
                    }
                    .disabled(viewModel.isSyncing || viewModel.isBindingAccount)
                }
            } label: {
                Label("WHOOP account", systemImage: "ellipsis.circle")
            }
        }
    }

    private var accountActionTitle: LocalizedStringKey {
        switch viewModel.authStatus {
        case .reconnectRequired:
            return "Reconnect"
        case .authenticated, .disconnected:
            return "Connect"
        }
    }
}
