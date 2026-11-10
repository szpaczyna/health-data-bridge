import Foundation

enum AuthStatus: Equatable {
    case disconnected
    case authenticated(email: String)
    case reconnectRequired(reason: String)
}

enum WhoopWebSession {
    static let accessTokenCookie = "whoop-auth-token"
    static let refreshTokenCookie = "whoop-auth-refresh-token"
    static let userCookie = "whoop-auth-user"

    static func tokenBundle(from cookies: [String: String]) throws -> TokenBundle {
        guard let accessToken = nonEmpty(cookies[accessTokenCookie]) else {
            throw WhoopAuthError.webSessionMissingAccessToken
        }
        guard let refreshToken = nonEmpty(cookies[refreshTokenCookie]) else {
            throw WhoopAuthError.webSessionMissingRefreshToken
        }
        let expiresAt = try expiry(ofJWT: accessToken)
        let email = try email(fromUserCookie: cookies[userCookie])
        return TokenBundle(
            email: email,
            accessToken: accessToken,
            refreshToken: refreshToken,
            idToken: "",
            tokenType: "Bearer",
            expiresAt: expiresAt
        )
    }

    private static func nonEmpty(_ value: String?) -> String? {
        guard let trimmed = value?.trimmingCharacters(in: .whitespacesAndNewlines), !trimmed.isEmpty else {
            return nil
        }
        return trimmed
    }

    private static func expiry(ofJWT token: String) throws -> Date {
        let parts = token.split(separator: ".", omittingEmptySubsequences: false)
        guard parts.count == 3 else {
            throw WhoopAuthError.webSessionMalformedAccessToken
        }
        var base64 = parts[1]
            .replacingOccurrences(of: "-", with: "+")
            .replacingOccurrences(of: "_", with: "/")
        let remainder = base64.count % 4
        if remainder > 0 {
            base64 += String(repeating: "=", count: 4 - remainder)
        }
        guard
            let data = Data(base64Encoded: base64),
            let payload = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
            let exp = payload["exp"] as? NSNumber,
            CFGetTypeID(exp) != CFBooleanGetTypeID()
        else {
            throw WhoopAuthError.webSessionMalformedAccessToken
        }
        return Date(timeIntervalSince1970: exp.doubleValue)
    }

    private static func email(fromUserCookie value: String?) throws -> String {
        guard let value else {
            throw WhoopAuthError.webSessionMissingEmail
        }
        let decoded = value.removingPercentEncoding ?? value
        guard
            let data = decoded.data(using: .utf8),
            let user = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
            let email = nonEmpty(user["email"] as? String)
        else {
            throw WhoopAuthError.webSessionMissingEmail
        }
        return email
    }
}

enum WhoopCognitoClientIDMode: Equatable {
    case emptyForWhoopProxy
    case explicit(String)

    var requestValue: String {
        switch self {
        case .emptyForWhoopProxy:
            return ""
        case let .explicit(value):
            return value.trimmingCharacters(in: .whitespacesAndNewlines)
        }
    }
}

struct WhoopAuthConfiguration: Equatable {
    static let infoPlistClientIDKey = "WHOOPCognitoClientID"
    static let environmentClientIDKey = "WHOOP_COGNITO_CLIENT_ID"

    var cognitoURL: URL
    var clientIDMode: WhoopCognitoClientIDMode

    init(
        cognitoURL: URL = URL(string: "https://api.prod.whoop.com/auth-service/v3/whoop/")!,
        clientIDMode: WhoopCognitoClientIDMode = Self.defaultClientIDMode()
    ) {
        self.cognitoURL = cognitoURL
        self.clientIDMode = clientIDMode
    }

    var clientID: String {
        clientIDMode.requestValue
    }

    private static func defaultClientIDMode() -> WhoopCognitoClientIDMode {
        if let environmentValue = usableClientID(ProcessInfo.processInfo.environment[environmentClientIDKey]) {
            return .explicit(environmentValue)
        }
        if let infoPlistValue = usableClientID(Bundle.main.object(forInfoDictionaryKey: infoPlistClientIDKey) as? String) {
            return .explicit(infoPlistValue)
        }

        // The known WHOOP proxy endpoint accepts Cognito-shaped requests while
        // inferring its Cognito app client server-side. Keep this explicit so a
        // future real client id can be configured without hunting string literals.
        return .emptyForWhoopProxy
    }

    private static func usableClientID(_ value: String?) -> String? {
        guard let value else { return nil }
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, !trimmed.hasPrefix("$(") else {
            return nil
        }
        return trimmed
    }
}

final class WhoopAuthService {
    private let tokenStore: any TokenStoring
    private let session: URLSession
    private let configuration: WhoopAuthConfiguration

    init(
        tokenStore: any TokenStoring,
        session: URLSession = .shared,
        configuration: WhoopAuthConfiguration = WhoopAuthConfiguration()
    ) {
        self.tokenStore = tokenStore
        self.session = session
        self.configuration = configuration
    }

    func currentStatus() -> AuthStatus {
        do {
            guard let bundle = try tokenStore.load() else {
                return .disconnected
            }
            if bundle.refreshToken.isEmpty {
                return .reconnectRequired(reason: "Missing refresh token.")
            }
            return .authenticated(email: bundle.email)
        } catch {
            return .reconnectRequired(reason: error.localizedDescription)
        }
    }

    func signIn(webCookies: [String: String]) throws -> TokenBundle {
        let bundle = try WhoopWebSession.tokenBundle(from: webCookies)
        try tokenStore.save(bundle)
        AppLog.auth.info("WHOOP web sign-in completed for \(SensitiveTextSanitizer.redact(bundle.email), privacy: .public)")
        return bundle
    }

    func validAccessToken() async throws -> String {
        guard let bundle = try tokenStore.load() else {
            throw WhoopAuthError.notAuthenticated
        }
        if bundle.expiresAt.timeIntervalSinceNow > 60 {
            return bundle.accessToken
        }
        return try await refresh().accessToken
    }

    @discardableResult
    func refresh() async throws -> TokenBundle {
        guard let current = try tokenStore.load() else {
            throw WhoopAuthError.notAuthenticated
        }
        AppLog.auth.info("Refreshing WHOOP access token.")
        let response = try await callCognito(
            target: "InitiateAuth",
            body: CognitoInitiateAuthRequest(
                AuthFlow: "REFRESH_TOKEN_AUTH",
                AuthParameters: [
                    "REFRESH_TOKEN": current.refreshToken
                ],
                ClientId: configuration.clientID
            )
        )

        guard let auth = response.AuthenticationResult else {
            throw WhoopAuthError.unexpectedCognitoResponse
        }
        let refreshed = makeTokenBundle(
            email: current.email,
            auth: auth,
            fallbackRefreshToken: current.refreshToken
        )
        try tokenStore.save(refreshed)
        return refreshed
    }

    func disconnect() throws {
        try tokenStore.delete()
    }

    private func callCognito<T: Encodable>(target: String, body: T) async throws -> CognitoResponse {
        var request = URLRequest(url: configuration.cognitoURL)
        request.httpMethod = "POST"
        request.setValue("application/x-amz-json-1.1", forHTTPHeaderField: "content-type")
        request.setValue("AWSCognitoIdentityProviderService.\(target)", forHTTPHeaderField: "x-amz-target")
        request.setValue("attempt=1; max=1", forHTTPHeaderField: "amz-sdk-request")
        request.setValue(UUID().uuidString, forHTTPHeaderField: "amz-sdk-invocation-id")
        request.setValue("aws-sdk-swift/1.5.86 ua/2.1 api/cognito_identity_provider#1.5.86 os/ios lang/swift", forHTTPHeaderField: "user-agent")
        request.setValue("*/*", forHTTPHeaderField: "accept")
        request.httpBody = try JSONEncoder().encode(body)

        let start = Date()
        let (data, response) = try await session.data(for: request)
        let elapsed = Date().timeIntervalSince(start)
        guard let http = response as? HTTPURLResponse else {
            throw WhoopAuthError.invalidHTTPResponse
        }

        AppLog.auth.info("Cognito \(target, privacy: .public) status=\(http.statusCode) elapsed=\(elapsed, privacy: .public)")
        guard (200..<300).contains(http.statusCode) else {
            throw WhoopAuthError.cognitoRejected(status: http.statusCode, message: Self.sanitizedMessage(from: data))
        }
        return try JSONDecoder().decode(CognitoResponse.self, from: data)
    }

    private func makeTokenBundle(email: String, auth: CognitoAuthenticationResult, fallbackRefreshToken: String?) -> TokenBundle {
        TokenBundle(
            email: email,
            accessToken: auth.AccessToken,
            refreshToken: auth.RefreshToken ?? fallbackRefreshToken ?? "",
            idToken: auth.IdToken,
            tokenType: auth.TokenType,
            expiresAt: Date().addingTimeInterval(TimeInterval(auth.ExpiresIn))
        )
    }

    private static func sanitizedMessage(from data: Data) -> String {
        guard !data.isEmpty else { return "empty response" }
        if let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
            let type = object["__type"] as? String ?? "error"
            let message = object["message"] as? String ?? object["error"] as? String ?? "no message"
            return SensitiveTextSanitizer.redact("\(type): \(message)")
        }
        return "non-JSON error body"
    }
}

private struct CognitoInitiateAuthRequest: Encodable {
    var AuthFlow: String
    var AuthParameters: [String: String]
    var ClientId: String
}

private struct CognitoResponse: Decodable {
    var AuthenticationResult: CognitoAuthenticationResult?
}

private struct CognitoAuthenticationResult: Decodable {
    var AccessToken: String
    var RefreshToken: String?
    var IdToken: String
    var ExpiresIn: Int
    var TokenType: String
}

enum WhoopAuthError: Error, LocalizedError {
    case notAuthenticated
    case unexpectedCognitoResponse
    case invalidHTTPResponse
    case cognitoRejected(status: Int, message: String)
    case webSessionMissingAccessToken
    case webSessionMissingRefreshToken
    case webSessionMalformedAccessToken
    case webSessionMissingEmail

    var errorDescription: String? {
        switch self {
        case .notAuthenticated:
            return "WHOOP session is not authenticated."
        case .unexpectedCognitoResponse:
            return "WHOOP authentication returned an unexpected response."
        case .invalidHTTPResponse:
            return "WHOOP authentication did not return an HTTP response."
        case let .cognitoRejected(status, message):
            return "WHOOP authentication failed (\(status)): \(message)"
        case .webSessionMissingAccessToken:
            return "WHOOP sign-in did not provide an access token."
        case .webSessionMissingRefreshToken:
            return "WHOOP sign-in did not provide a refresh token."
        case .webSessionMalformedAccessToken:
            return "WHOOP sign-in returned an unreadable access token."
        case .webSessionMissingEmail:
            return "WHOOP sign-in did not provide the account email."
        }
    }
}
