#if os(iOS)
import SwiftUI
import WebKit

struct WhoopLoginWebView: UIViewRepresentable {
    static let loginURL = URL(string: "https://app.whoop.com")!

    let onSession: ([String: String]) -> Void

    func makeCoordinator() -> Coordinator {
        Coordinator(onSession: onSession)
    }

    func makeUIView(context: Context) -> WKWebView {
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = .nonPersistent()
        let webView = WKWebView(frame: .zero, configuration: configuration)
        webView.accessibilityIdentifier = "auth.webLogin"
        webView.navigationDelegate = context.coordinator
        context.coordinator.startObserving(webView.configuration.websiteDataStore.httpCookieStore)
        webView.load(URLRequest(url: Self.loginURL))
        return webView
    }

    func updateUIView(_ uiView: WKWebView, context: Context) {}

    static func dismantleUIView(_ uiView: WKWebView, coordinator: Coordinator) {
        coordinator.stopObserving()
    }

    final class Coordinator: NSObject, WKNavigationDelegate, WKHTTPCookieStoreObserver {
        private let onSession: ([String: String]) -> Void
        private var cookieStore: WKHTTPCookieStore?
        private var didDeliver = false

        init(onSession: @escaping ([String: String]) -> Void) {
            self.onSession = onSession
        }

        func startObserving(_ store: WKHTTPCookieStore) {
            cookieStore = store
            store.add(self)
        }

        func stopObserving() {
            cookieStore?.remove(self)
            cookieStore = nil
        }

        func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
            readCookies(in: webView.configuration.websiteDataStore.httpCookieStore)
        }

        func cookiesDidChange(in cookieStore: WKHTTPCookieStore) {
            readCookies(in: cookieStore)
        }

        private func readCookies(in store: WKHTTPCookieStore) {
            store.getAllCookies { [weak self] cookies in
                Task { @MainActor [weak self] in
                    self?.handle(cookies)
                }
            }
        }

        @MainActor
        private func handle(_ cookies: [HTTPCookie]) {
            guard !didDeliver else { return }
            var values: [String: String] = [:]
            for cookie in cookies where cookie.domain.hasSuffix("whoop.com") && !cookie.value.isEmpty {
                values[cookie.name] = cookie.value
            }
            // The site sets its auth cookies one at a time; delivering early would lock in a partial session.
            guard values[WhoopWebSession.accessTokenCookie] != nil,
                  values[WhoopWebSession.refreshTokenCookie] != nil,
                  values[WhoopWebSession.userCookie] != nil else { return }
            didDeliver = true
            onSession(values)
        }
    }
}
#else
import SwiftUI

struct WhoopLoginWebView: View {
    let onSession: ([String: String]) -> Void

    var body: some View { EmptyView() }
}
#endif
