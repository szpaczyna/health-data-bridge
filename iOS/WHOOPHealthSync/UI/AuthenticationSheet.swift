import SwiftUI

struct AuthenticationSheet: View {
    @ObservedObject var viewModel: SyncViewModel
    var onConnected: () -> Void = {}
    @Environment(\.dismiss) private var dismiss
    @State private var loginError: String?
    @State private var loadFailed = false
    @State private var webViewID = UUID()

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                Text("Sign in with your WHOOP account below.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .padding()

                if let loginError {
                    Text(loginError)
                        .foregroundStyle(.red)
                        .accessibilityIdentifier("auth.error")
                    Button("Try again") {
                        self.loginError = nil
                        webViewID = UUID()
                    }
                    .padding()
                }

                if loadFailed {
                    Text("Could not load the WHOOP sign-in page. Check your connection and retry.")
                        .foregroundStyle(.red)
                        .multilineTextAlignment(.center)
                        .padding(.horizontal)
                        .accessibilityIdentifier("auth.loadError")
                    Button("Retry") {
                        loadFailed = false
                        webViewID = UUID()
                    }
                    .padding()
                    .accessibilityIdentifier("auth.retryLoad")
                }

                if let cookies = viewModel.fixtureWebCookies {
                    Button {
                        complete(cookies)
                    } label: {
                        Text(verbatim: "Use test session")
                    }
                    .accessibilityIdentifier("auth.fixtureLogin")
                    Spacer()
                } else {
                    WhoopLoginWebView(onSession: complete, onLoadFailure: { loadFailed = true })
                        .id(webViewID)
                }
            }
            .navigationTitle("Connect WHOOP")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") {
                        dismiss()
                    }
                }
            }
        }
    }

    private func complete(_ cookies: [String: String]) {
        viewModel.signIn(webCookies: cookies)
        switch viewModel.authStatus {
        case .authenticated:
            onConnected()
            dismiss()
        case let .reconnectRequired(reason):
            loginError = reason
        case .disconnected:
            break
        }
    }
}
