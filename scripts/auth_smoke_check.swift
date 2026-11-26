import Foundation

@main
struct AuthSmokeCheck {
    static func main() async throws {
        let tokenStore = InMemoryTokenStore()
        MockCognitoURLProtocol.reset()

        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [MockCognitoURLProtocol.self]
        let session = URLSession(configuration: configuration)

        let auth = WhoopAuthService(tokenStore: tokenStore, session: session)
        expect(auth.currentStatus() == .disconnected, "Fresh auth service should start disconnected.")

        let accessToken = fixtureJWT(exp: 2_000_000_000)
        let validCookies = [
            WhoopWebSession.accessTokenCookie: " \(accessToken) ",
            WhoopWebSession.refreshTokenCookie: "web-refresh-token",
            WhoopWebSession.userCookie: "%7B%22email%22%3A%22jose%40example.com%22%2C%22id%22%3A1%7D"
        ]
        let tokenBundle = try auth.signIn(webCookies: validCookies)
        expect(tokenBundle.email == "jose@example.com", "Web sign-in should read the account email from the user cookie.")
        expect(tokenBundle.accessToken == accessToken, "Web sign-in should save the trimmed access token.")
        expect(tokenBundle.refreshToken == "web-refresh-token", "Web sign-in should save the refresh token.")
        expect(tokenBundle.idToken == "", "Web sign-in has no id token.")
        expect(tokenBundle.tokenType == "Bearer", "Web sign-in should use Bearer tokens.")
        expect(tokenBundle.expiresAt == Date(timeIntervalSince1970: 2_000_000_000), "Web sign-in should read expiry from the JWT exp claim.")
        expect(tokenStore.bundle == tokenBundle, "Web sign-in should save tokens.")
        expect(auth.currentStatus() == .authenticated(email: "jose@example.com"), "Saved refresh token should mark auth as authenticated.")
        expect(MockCognitoURLProtocol.requests.isEmpty, "Web sign-in should not perform network requests.")
        expect(WhoopWebSession.containsEmail(userCookie: #"{"id":1,"email":"jose@example.com"}"#), "Unencoded full user cookie should count as complete.")
        expect(!WhoopWebSession.containsEmail(userCookie: #"{"id":1,"firstName":"Jose"}"#), "Short user cookie without email should not count as complete.")
        for domain in ["whoop.com", ".whoop.com", "app.whoop.com"] {
            expect(WhoopWebSession.isWhoopCookieDomain(domain), "Cookie domain \(domain) should be accepted.")
        }
        for domain in ["evilwhoop.com", ".evilwhoop.com", "whoop.com.evil.example"] {
            expect(!WhoopWebSession.isWhoopCookieDomain(domain), "Cookie domain \(domain) should be rejected.")
        }

        let invalidCases: [(String, [String: String], WhoopAuthError)] = [
            ("missing access token", validCookies.removing(WhoopWebSession.accessTokenCookie), .webSessionMissingAccessToken),
            ("empty access token", validCookies.setting(WhoopWebSession.accessTokenCookie, "  "), .webSessionMissingAccessToken),
            ("missing refresh token", validCookies.removing(WhoopWebSession.refreshTokenCookie), .webSessionMissingRefreshToken),
            ("two-part JWT", validCookies.setting(WhoopWebSession.accessTokenCookie, "header.payload"), .webSessionMalformedAccessToken),
            ("non-base64 payload", validCookies.setting(WhoopWebSession.accessTokenCookie, "header.!!!.signature"), .webSessionMalformedAccessToken),
            ("payload without exp", validCookies.setting(WhoopWebSession.accessTokenCookie, fixtureJWT(payload: ["token_use": "access"])), .webSessionMalformedAccessToken),
            ("missing user cookie", validCookies.removing(WhoopWebSession.userCookie), .webSessionMissingEmail),
            ("user JSON without email", validCookies.setting(WhoopWebSession.userCookie, "%7B%22id%22%3A1%7D"), .webSessionMissingEmail)
        ]
        let seededBundle = TokenBundle(
            email: "seed@example.com",
            accessToken: "seed-access",
            refreshToken: "seed-refresh",
            idToken: "",
            tokenType: "Bearer",
            expiresAt: Date(timeIntervalSince1970: 1_000)
        )
        for (name, cookies, expectedError) in invalidCases {
            let invalidStore = InMemoryTokenStore()
            invalidStore.bundle = seededBundle
            let invalidAuth = WhoopAuthService(tokenStore: invalidStore, session: session)
            do {
                _ = try invalidAuth.signIn(webCookies: cookies)
                fatalError("Web sign-in with \(name) should throw.")
            } catch let error as WhoopAuthError {
                expect(error.localizedDescription == expectedError.localizedDescription, "Web sign-in with \(name) should throw \(expectedError).")
                if let token = cookies[WhoopWebSession.accessTokenCookie], !token.trimmingCharacters(in: .whitespaces).isEmpty {
                    expect(!error.localizedDescription.contains(token), "Web sign-in error for \(name) should not contain the token.")
                }
            }
            expect(invalidStore.bundle == seededBundle, "Web sign-in with \(name) should leave the token store untouched.")
        }

        tokenStore.bundle?.expiresAt = Date().addingTimeInterval(-10)
        let refreshedToken = try await auth.validAccessToken()
        expect(refreshedToken == "access-after-refresh", "Expired access token should trigger refresh.")
        expect(tokenStore.bundle?.refreshToken == "web-refresh-token", "Refresh flow should retain old refresh token when Cognito omits a new one.")

        let requests = MockCognitoURLProtocol.requests
        expect(requests.count == 1, "Auth smoke should perform one refresh request.")
        expect(requests[0].body["AuthFlow"] as? String == "REFRESH_TOKEN_AUTH", "Refresh request should use REFRESH_TOKEN_AUTH.")
        expect((requests[0].body["AuthParameters"] as? [String: String])?["REFRESH_TOKEN"] == "web-refresh-token", "Refresh request should send the saved refresh token.")
        expect(requests[0].body["ClientId"] as? String == "", "Default WHOOP proxy request should intentionally send an empty ClientId.")

        MockCognitoURLProtocol.reset()
        let explicitStore = InMemoryTokenStore()
        explicitStore.bundle = tokenBundle
        let explicitAuth = WhoopAuthService(
            tokenStore: explicitStore,
            session: session,
            configuration: WhoopAuthConfiguration(clientIDMode: .explicit("37365lrcda1js3fapqfe2n40eh"))
        )
        _ = try await explicitAuth.refresh()
        expect(MockCognitoURLProtocol.requests.first?.body["ClientId"] as? String == "37365lrcda1js3fapqfe2n40eh", "Auth configuration should send the explicit Cognito ClientId on refresh.")

        MockCognitoURLProtocol.reset()
        MockCognitoURLProtocol.overrideStatusCode = 400
        MockCognitoURLProtocol.overrideResponseBody = [
            "__type": "NotAuthorizedException",
            "message": "Rejected jose@example.com Authorization: Bearer secret-token password=secret-password refreshToken=refresh-secret jwt=header.payload.signature"
        ]
        let rejectedStore = InMemoryTokenStore()
        rejectedStore.bundle = tokenBundle
        let rejectedAuth = WhoopAuthService(
            tokenStore: rejectedStore,
            session: session
        )
        do {
            _ = try await rejectedAuth.refresh()
            fatalError("Rejected Cognito responses should throw.")
        } catch {
            let message = error.localizedDescription
            expect(!message.contains("jose@example.com"), "Rejected Cognito error should redact emails.")
            expect(!message.contains("secret-token"), "Rejected Cognito error should redact bearer token material.")
            expect(!message.contains("secret-password"), "Rejected Cognito error should redact password material.")
            expect(!message.contains("refresh-secret"), "Rejected Cognito error should redact refresh token material.")
            expect(!message.contains("header.payload.signature"), "Rejected Cognito error should redact JWT-like values.")
            expect(message.contains("[redacted-email]"), "Rejected Cognito error should include the email redaction marker.")
            expect(message.contains("Bearer [redacted-token]"), "Rejected Cognito error should include the bearer redaction marker.")
        }

        try auth.disconnect()
        expect(tokenStore.bundle == nil, "Disconnect should remove saved tokens.")
        expect(auth.currentStatus() == .disconnected, "Disconnect should return to disconnected status.")

        try await checkConcurrentRefreshSharesOneRequest(session: session, bundle: tokenBundle)
        try await checkSignInDuringRefreshWins(session: session, bundle: tokenBundle)
        try await checkDisconnectDuringRefreshWins(session: session, bundle: tokenBundle)

        print("WhoopAuthService smoke check passed")
    }

    private static func expiredCopy(of bundle: TokenBundle) -> TokenBundle {
        var copy = bundle
        copy.expiresAt = Date().addingTimeInterval(-10)
        return copy
    }

    private static func checkConcurrentRefreshSharesOneRequest(session: URLSession, bundle: TokenBundle) async throws {
        MockCognitoURLProtocol.reset()
        MockCognitoURLProtocol.holdResponses = true
        let store = InMemoryTokenStore()
        store.bundle = expiredCopy(of: bundle)
        let auth = WhoopAuthService(tokenStore: store, session: session)

        let first = Task { try await auth.validAccessToken() }
        let second = Task { try await auth.validAccessToken() }
        let reached = await MockCognitoURLProtocol.waitForRequests(1)
        expect(reached, "Concurrent refresh should reach Cognito.")
        // Give an unserialized second caller time to send its own request before releasing.
        _ = await MockCognitoURLProtocol.waitForRequests(2)
        MockCognitoURLProtocol.releasePending()
        let firstToken = try await first.value
        let secondToken = try await second.value

        expect(MockCognitoURLProtocol.requests.count == 1, "Concurrent validAccessToken calls should share one refresh request.")
        expect(firstToken == secondToken, "Concurrent validAccessToken calls should return the same token.")
        expect(firstToken == "access-after-refresh", "Concurrent validAccessToken calls should return the refreshed token.")
    }

    private static func checkSignInDuringRefreshWins(session: URLSession, bundle: TokenBundle) async throws {
        MockCognitoURLProtocol.reset()
        MockCognitoURLProtocol.holdResponses = true
        let store = InMemoryTokenStore()
        store.bundle = expiredCopy(of: bundle)
        let auth = WhoopAuthService(tokenStore: store, session: session)

        let staleRefresh = Task { try await auth.refresh() }
        let reached = await MockCognitoURLProtocol.waitForRequests(1)
        expect(reached, "Held refresh should reach Cognito.")
        let newAccessToken = fixtureJWT(exp: 2_100_000_000)
        let newBundle = try auth.signIn(webCookies: [
            WhoopWebSession.accessTokenCookie: newAccessToken,
            WhoopWebSession.refreshTokenCookie: "new-refresh-token",
            WhoopWebSession.userCookie: "%7B%22email%22%3A%22new%40example.com%22%2C%22id%22%3A2%7D"
        ])
        MockCognitoURLProtocol.releasePending()
        let staleResult = await staleRefresh.result

        expect(store.bundle == newBundle, "A refresh started before sign-in should not overwrite the new session.")
        expect(store.bundle?.email == "new@example.com", "Sign-in during refresh should keep the new account email.")
        expect(store.bundle?.accessToken == newAccessToken, "Sign-in during refresh should keep the new access token.")
        expect(store.bundle?.refreshToken == "new-refresh-token", "Sign-in during refresh should keep the new refresh token.")
        switch staleResult {
        case .success:
            fatalError("A refresh overtaken by sign-in should throw.")
        case let .failure(error):
            expect(
                error.localizedDescription == WhoopAuthError.sessionChanged.localizedDescription,
                "A refresh overtaken by sign-in should throw sessionChanged."
            )
        }
    }

    private static func checkDisconnectDuringRefreshWins(session: URLSession, bundle: TokenBundle) async throws {
        MockCognitoURLProtocol.reset()
        MockCognitoURLProtocol.holdResponses = true
        let store = InMemoryTokenStore()
        store.bundle = expiredCopy(of: bundle)
        let auth = WhoopAuthService(tokenStore: store, session: session)

        let staleRefresh = Task { try await auth.refresh() }
        let reached = await MockCognitoURLProtocol.waitForRequests(1)
        expect(reached, "Held refresh should reach Cognito.")
        try auth.disconnect()
        MockCognitoURLProtocol.releasePending()
        _ = await staleRefresh.result

        expect(store.bundle == nil, "A refresh started before disconnect should not restore tokens.")
        expect(auth.currentStatus() == .disconnected, "Disconnect during refresh should stay disconnected.")
    }

    private static func expect(_ condition: @autoclosure () -> Bool, _ message: String) {
        guard condition() else {
            fatalError(message)
        }
    }

    private static func fixtureJWT(exp: Int) -> String {
        fixtureJWT(payload: ["exp": exp, "token_use": "access"])
    }

    private static func fixtureJWT(payload: [String: Any]) -> String {
        let header = base64URL(try! JSONSerialization.data(withJSONObject: ["alg": "RS256", "typ": "JWT"]))
        let body = base64URL(try! JSONSerialization.data(withJSONObject: payload))
        return "\(header).\(body).fixture-signature"
    }

    private static func base64URL(_ data: Data) -> String {
        data.base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }
}

private extension Dictionary where Key == String, Value == String {
    func removing(_ key: String) -> [String: String] {
        var copy = self
        copy.removeValue(forKey: key)
        return copy
    }

    func setting(_ key: String, _ value: String) -> [String: String] {
        var copy = self
        copy[key] = value
        return copy
    }
}

private final class InMemoryTokenStore: TokenStoring {
    private let lock = NSLock()
    private var storedBundle: TokenBundle?

    var bundle: TokenBundle? {
        get { lock.lock(); defer { lock.unlock() }; return storedBundle }
        set { lock.lock(); defer { lock.unlock() }; storedBundle = newValue }
    }

    func load() throws -> TokenBundle? {
        bundle
    }

    func save(_ bundle: TokenBundle) throws {
        self.bundle = bundle
    }

    func delete() throws {
        bundle = nil
    }
}

private final class MockCognitoURLProtocol: URLProtocol {
    struct RecordedRequest {
        var headers: [String: String]
        var body: [String: Any]
    }

    private static let lock = NSLock()
    private static var recordedRequests: [RecordedRequest] = []
    private static var pendingCompletions: [() -> Void] = []
    static var overrideStatusCode: Int?
    static var overrideResponseBody: [String: Any]?
    private static var heldFlag = false

    static var holdResponses: Bool {
        get { lock.lock(); defer { lock.unlock() }; return heldFlag }
        set { lock.lock(); defer { lock.unlock() }; heldFlag = newValue }
    }

    static var requests: [RecordedRequest] {
        lock.lock(); defer { lock.unlock() }
        return recordedRequests
    }

    static func reset() {
        releasePending()
        lock.lock()
        recordedRequests.removeAll()
        lock.unlock()
        overrideStatusCode = nil
        overrideResponseBody = nil
        holdResponses = false
    }

    static func releasePending() {
        lock.lock()
        let completions = pendingCompletions
        pendingCompletions.removeAll()
        lock.unlock()
        completions.forEach { $0() }
    }

    static func waitForRequests(_ count: Int) async -> Bool {
        for _ in 0..<200 {
            if requests.count >= count {
                return true
            }
            try? await Task.sleep(nanoseconds: 10_000_000)
        }
        return requests.count >= count
    }

    override class func canInit(with request: URLRequest) -> Bool {
        request.url?.absoluteString == "https://api.prod.whoop.com/auth-service/v3/whoop/"
    }

    override class func canonicalRequest(for request: URLRequest) -> URLRequest {
        request
    }

    override func startLoading() {
        do {
            let bodyData = try requestBodyData()
            let body = try JSONSerialization.jsonObject(with: bodyData, options: []) as? [String: Any] ?? [:]
            let recorded = RecordedRequest(headers: request.allHTTPHeaderFields ?? [:], body: body)

            let statusCode = MockCognitoURLProtocol.overrideStatusCode ?? 200
            let responseBody = try MockCognitoURLProtocol.overrideResponseBody ?? response(for: body)
            let responseData = try JSONSerialization.data(withJSONObject: responseBody, options: [])
            let response = HTTPURLResponse(
                url: request.url!,
                statusCode: statusCode,
                httpVersion: "HTTP/1.1",
                headerFields: ["Content-Type": "application/json"]
            )!
            let complete = { [self] in
                client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
                client?.urlProtocol(self, didLoad: responseData)
                client?.urlProtocolDidFinishLoading(self)
            }
            MockCognitoURLProtocol.lock.lock()
            MockCognitoURLProtocol.recordedRequests.append(recorded)
            let hold = MockCognitoURLProtocol.heldFlag
            if hold {
                MockCognitoURLProtocol.pendingCompletions.append(complete)
            }
            MockCognitoURLProtocol.lock.unlock()
            if !hold {
                complete()
            }
        } catch {
            client?.urlProtocol(self, didFailWithError: error)
        }
    }

    override func stopLoading() {}

    private func response(for body: [String: Any]) throws -> [String: Any] {
        switch body["AuthFlow"] as? String {
        case "REFRESH_TOKEN_AUTH":
            return [
                "AuthenticationResult": [
                    "AccessToken": "access-after-refresh",
                    "IdToken": "id-after-refresh",
                    "ExpiresIn": 3600,
                    "TokenType": "Bearer"
                ]
            ]
        default:
            return [:]
        }
    }

    private func requestBodyData() throws -> Data {
        if let data = request.httpBody {
            return data
        }
        guard let stream = request.httpBodyStream else {
            return Data()
        }

        stream.open()
        defer { stream.close() }

        var data = Data()
        let bufferSize = 1_024
        let buffer = UnsafeMutablePointer<UInt8>.allocate(capacity: bufferSize)
        defer { buffer.deallocate() }

        while stream.hasBytesAvailable {
            let read = stream.read(buffer, maxLength: bufferSize)
            if read < 0 {
                throw stream.streamError ?? CocoaError(.fileReadUnknown)
            }
            if read == 0 {
                break
            }
            data.append(buffer, count: read)
        }
        return data
    }
}
