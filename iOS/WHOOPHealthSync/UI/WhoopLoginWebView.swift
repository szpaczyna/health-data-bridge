#if os(iOS)
import SwiftUI
import WebKit

struct WhoopLoginWebView: UIViewRepresentable {
    static let loginURL = URL(string: "https://app.whoop.com")!

    let onSession: ([String: String]) -> Void
    var onLoadFailure: () -> Void = {}

    func makeCoordinator() -> Coordinator {
        Coordinator(onSession: onSession, onLoadFailure: onLoadFailure)
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
        private let onLoadFailure: () -> Void
        private var cookieStore: WKHTTPCookieStore?
        private var didDeliver = false

        init(onSession: @escaping ([String: String]) -> Void, onLoadFailure: @escaping () -> Void) {
            self.onSession = onSession
            self.onLoadFailure = onLoadFailure
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

        func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
            reportLoadFailure(error)
        }

        func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
            reportLoadFailure(error)
        }

        private func reportLoadFailure(_ error: Error) {
            let error = error as NSError
            // WebKit reports a superseded navigation as cancelled; the newer navigation is still loading.
            if error.domain == NSURLErrorDomain, error.code == NSURLErrorCancelled { return }
            onLoadFailure()
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
            for cookie in cookies where WhoopWebSession.isWhoopCookieDomain(cookie.domain) && !cookie.value.isEmpty {
                // WHOOP first sets a short user cookie without the email and replaces it after the dashboard loads.
                if cookie.name == WhoopWebSession.userCookie, !WhoopWebSession.containsEmail(userCookie: cookie.value) {
                    continue
                }
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
    var onLoadFailure: () -> Void = {}

    var body: some View { EmptyView() }
}
#endif
