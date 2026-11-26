import Foundation
import WHOOPHealthSyncCore

@main
struct WhoopAPISmokeCheck {
    static func main() async throws {
        MockWhoopURLProtocol.reset()

        let tokenStore = InMemoryTokenStore()
        tokenStore.bundle = TokenBundle(
            email: "jose@example.com",
            accessToken: "stale-access",
            refreshToken: "refresh-token",
            idToken: "id-token",
            tokenType: "Bearer",
            expiresAt: Date().addingTimeInterval(3_600)
        )

        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [MockWhoopURLProtocol.self]
        let session = URLSession(configuration: configuration)
        let auth = WhoopAuthService(tokenStore: tokenStore, session: session)
        let client = WhoopAPIClient(auth: auth, session: session)

        let user = try await client.fetchCurrentUser()
        expect(user.id == "98765", "User endpoint should parse auth-service user ID.")
        expect(tokenStore.bundle?.accessToken == "fresh-access", "401 response should refresh the access token.")
        expect(tokenStore.bundle?.refreshToken == "refresh-token", "Refresh should retain existing refresh token when not rotated.")

        let start = iso("2026-07-12T00:00:00.000Z")
        let end = iso("2026-07-13T00:00:00.000Z")
        let activities = try await client.fetchSleepActivities(userID: user.id, start: start, end: end)
        expect(activities.map(\.activityID) == ["sleep-api-1"], "Cycles endpoint should parse sleep activities.")

        let sessionSleep = try await client.fetchSleepSession(activity: activities[0])
        expect(sessionSleep.whoopSleepID == "sleep-api-1", "Sleep endpoint should preserve WHOOP sleep ID.")
        expect(sessionSleep.stages.map(\.stage) == [.core, .rem], "Sleep endpoint should parse stage intervals.")

        let heartRate = try await client.fetchHeartRate(userID: user.id, start: start, end: start.addingTimeInterval(12), stepSeconds: 6)
        expect(heartRate.map(\.bpm) == [60, 61], "HR endpoint should parse WHOOP heart-rate values.")
        expect(heartRate.allSatisfy { $0.sourceStepSeconds == 6 }, "HR endpoint should preserve requested resolution.")

        let requests = MockWhoopURLProtocol.requests
        expect(requests.filter { $0.path == "/auth-service/v2/user" }.count == 2, "401 user request should be retried once after refresh.")
        expect(requests.contains { $0.path == "/auth-service/v3/whoop" && $0.body["AuthFlow"] as? String == "REFRESH_TOKEN_AUTH" }, "401 retry should call Cognito refresh flow.")

        let cyclesRequest = try request(path: "/core-details-bff/v0/cycles/details")
        expect(cyclesRequest.query["id"] == "98765", "Cycles request should include user ID.")
        expect(cyclesRequest.query["limit"] == "50", "Cycles request should include limit.")
        expect(cyclesRequest.query["startTime"] == WhoopDateCodec.isoString(start), "Cycles request should include ISO start.")
        expect(cyclesRequest.query["endTime"] == WhoopDateCodec.isoString(end), "Cycles request should include ISO end.")

        let sleepRequest = try request(path: "/sleep-service/v1/sleep-events")
        expect(sleepRequest.query["activityId"] == "sleep-api-1", "Sleep request should include activityId.")

        let heartRateRequest = try request(path: "/metrics-service/v1/metrics/user/98765")
        expect(heartRateRequest.query["name"] == "heart_rate", "HR request should ask for heart_rate.")
        expect(heartRateRequest.query["step"] == "6", "HR request should ask for 6-second step.")
        expect(heartRateRequest.headers["Authorization"] == "Bearer fresh-access", "Data requests after refresh should use fresh token.")

        MockWhoopURLProtocol.clearRequests()
        MockWhoopURLProtocol.prepareStaleUser(status: 403)
        tokenStore.bundle = TokenBundle(
            email: "jose@example.com",
            accessToken: "stale-access",
            refreshToken: "refresh-token",
            idToken: "id-token",
            tokenType: "Bearer",
            expiresAt: Date().addingTimeInterval(3_600)
        )
        let refreshedAfter403 = try await client.fetchCurrentUser()
        expect(refreshedAfter403.id == "98765", "403 user request should succeed after one token refresh.")
        expect(tokenStore.bundle?.accessToken == "fresh-access", "403 response should refresh the access token.")
        expect(MockWhoopURLProtocol.requests.filter { $0.path == "/auth-service/v2/user" }.count == 2, "403 user request should be retried once after refresh.")
        expect(MockWhoopURLProtocol.requests.contains { $0.path == "/auth-service/v3/whoop" && $0.body["AuthFlow"] as? String == "REFRESH_TOKEN_AUTH" }, "403 retry should call Cognito refresh flow.")

        MockWhoopURLProtocol.clearRequests()
        MockWhoopURLProtocol.cyclesReturnsEmpty = true
        let fallbackStart = iso("2026-07-12T10:00:00.000Z")
        let fallbackEnd = iso("2026-07-12T12:00:00.000Z")
        let fallbackDate = localDateString(for: fallbackStart)
        let fallbackActivities = try await client.fetchSleepActivities(userID: user.id, start: fallbackStart, end: fallbackEnd)
        expect(fallbackActivities.map(\.activityID) == ["deep-dive-sleep:\(fallbackDate)"], "Empty cycles response should fall back to deep-dive sleep discovery.")

        let fallbackSleep = try await client.fetchSleepSession(activity: fallbackActivities[0])
        expect(fallbackSleep.whoopSleepID == "deep-dive-sleep:\(fallbackDate)", "Deep-dive sleep should use a stable synthetic ID.")
        expect(fallbackSleep.stages.map(\.stage) == [.core, .deep, .awake], "Deep-dive fallback should parse hypnogram stages.")
        expect(MockWhoopURLProtocol.requests.filter { $0.path == "/home-service/v1/deep-dive/sleep" }.count == 1, "Deep-dive sleep session should be served from cache after discovery.")

        MockWhoopURLProtocol.clearRequests()
        _ = try await client.fetchSleepSession(activity: fallbackActivities[0])
        expect(MockWhoopURLProtocol.requests.filter { $0.path == "/home-service/v1/deep-dive/sleep" }.count == 1, "Deep-dive session cache should be consumed after one read so later calls can observe revisions.")

        MockWhoopURLProtocol.clearRequests()
        MockWhoopURLProtocol.cyclesReturnsEmpty = true
        MockWhoopURLProtocol.deepDiveSleepStatusCode = 404
        let missingFallbackActivities = try await client.fetchSleepActivities(userID: user.id, start: fallbackStart, end: fallbackEnd)
        expect(missingFallbackActivities.isEmpty, "Deep-dive 404 should be treated as no sleep for that date.")

        MockWhoopURLProtocol.clearRequests()
        MockWhoopURLProtocol.cyclesReturnsEmpty = true
        MockWhoopURLProtocol.deepDiveSleepStatusCode = 422
        do {
            _ = try await client.fetchSleepActivities(userID: user.id, start: fallbackStart, end: fallbackEnd)
            fatalError("Deep-dive contract errors should not be treated as empty sleep.")
        } catch let error as WhoopAPIError {
            guard case let .http(status, path, _) = error else {
                fatalError("Expected HTTP error from deep-dive contract failure.")
            }
            expect(status == 422, "Deep-dive 422 should propagate as an explicit API error.")
            expect(path == "/home-service/v1/deep-dive/sleep", "Deep-dive 422 should preserve the failing path.")
        }

        MockWhoopURLProtocol.clearRequests()
        MockWhoopURLProtocol.cyclesReturnsEmpty = false
        MockWhoopURLProtocol.deepDiveSleepStatusCode = 200
        MockWhoopURLProtocol.cyclesPerDay = true
        let longStart = iso("2026-05-01T00:00:00.000Z")
        let longEnd = longStart.addingTimeInterval(60 * 86_400)
        let longActivities = try await client.fetchSleepActivities(userID: user.id, start: longStart, end: longEnd)
        expect(Set(longActivities.map(\.activityID)).count == 60, "Sleep discovery should not drop nights past the 50-record cycles limit.")
        let longCyclesRequests = MockWhoopURLProtocol.requests.filter { $0.path == "/core-details-bff/v0/cycles/details" }
        expect(longCyclesRequests.allSatisfy { request in
            guard let start = request.query["startTime"].flatMap(WhoopDateCodec.date(from:)),
                  let end = request.query["endTime"].flatMap(WhoopDateCodec.date(from:)) else { return false }
            return end.timeIntervalSince(start) <= 7 * 86_400
        }, "Each cycles request should span at most seven days.")
        expect(longCyclesRequests.first?.query["startTime"] == WhoopDateCodec.isoString(longStart), "Sleep slices should start at the window start.")
        expect(longCyclesRequests.last?.query["endTime"] == WhoopDateCodec.isoString(longEnd), "Last sleep slice should end at the window end.")
        MockWhoopURLProtocol.cyclesPerDay = false

        MockWhoopURLProtocol.clearRequests()
        MockWhoopURLProtocol.heartRateStatusCode = 500
        MockWhoopURLProtocol.heartRateErrorBody = [
            "message": "Failure for jose@example.com Authorization: Bearer secret-token password=secret-password refreshToken=refresh-secret jwt=header.payload.signature"
        ]
        do {
            _ = try await client.fetchHeartRate(userID: user.id, start: start, end: start.addingTimeInterval(12), stepSeconds: 6)
            fatalError("Sensitive HR API failures should throw.")
        } catch let error as WhoopAPIError {
            let message = error.localizedDescription
            expect(!message.contains("jose@example.com"), "WHOOP API errors should redact emails at the client boundary.")
            expect(!message.contains("secret-token"), "WHOOP API errors should redact bearer token material at the client boundary.")
            expect(!message.contains("secret-password"), "WHOOP API errors should redact password material at the client boundary.")
            expect(!message.contains("refresh-secret"), "WHOOP API errors should redact refresh token material at the client boundary.")
            expect(!message.contains("header.payload.signature"), "WHOOP API errors should redact JWT-like values at the client boundary.")
            expect(message.contains("[redacted-email]"), "WHOOP API errors should include the email redaction marker.")
            expect(message.contains("Bearer [redacted-token]"), "WHOOP API errors should include the bearer redaction marker.")
            expect(!message.contains("98765"), "WHOOP API errors must not include the WHOOP user ID from the HR route.")
        }
        MockWhoopURLProtocol.heartRateStatusCode = 200
        expect(
            SensitiveTextSanitizer.redact("GET /metrics-service/v1/metrics/user/12345678 failed") == "GET /metrics-service/v1/metrics/user/[redacted-id] failed",
            "Sanitizer should redact numeric user IDs in paths."
        )

        var recordedSleeps: [TimeInterval] = []
        let recordingPolicy = WhoopAPIClient.RetryPolicy(maxRetries: 3, baseDelay: 0.5, maxDelay: 30, sleep: { recordedSleeps.append($0) })

        MockWhoopURLProtocol.userStatusCode = 429
        MockWhoopURLProtocol.rateLimitHeaders = ["x-ratelimit-reset": "inf"]
        do {
            _ = try await WhoopAPIClient(auth: auth, session: session, retryPolicy: recordingPolicy).fetchCurrentUser()
            fatalError("429 with a non-finite reset header should throw.")
        } catch let WhoopAPIError.http(status, _, _) {
            expect(status == 429, "Non-finite reset header should surface as 429.")
        }

        recordedSleeps.removeAll()
        MockWhoopURLProtocol.rateLimitHeaders = ["x-ratelimit-remaining": "0", "x-ratelimit-reset": "80000"]
        let longResetClient = WhoopAPIClient(auth: auth, session: session, retryPolicy: recordingPolicy)
        for _ in 0..<2 {
            do {
                _ = try await longResetClient.fetchCurrentUser()
                fatalError("429 with a reset beyond maxDelay should throw.")
            } catch let WhoopAPIError.http(status, path, _) {
                expect(status == 429, "Reset beyond maxDelay should surface as 429.")
                expect(path == "/auth-service/v2/user", "Long-reset 429 should name the route.")
            }
        }
        expect(recordedSleeps.allSatisfy { $0 <= 30 }, "Client must never sleep past RetryPolicy.maxDelay.")
        MockWhoopURLProtocol.userStatusCode = 200

        recordedSleeps.removeAll()
        let exhaustedClient = WhoopAPIClient(auth: auth, session: session, retryPolicy: recordingPolicy)
        _ = try await exhaustedClient.fetchCurrentUser()
        let exhaustedAt = Date()
        do {
            _ = try await exhaustedClient.fetchRecoveryCycleRecords(userID: user.id, window: TimeRange(start: start, end: end))
            fatalError("An exhausted budget with a long reset must defer recovery.")
        } catch let RecoverySyncError.rateLimited(date) {
            expect(date.timeIntervalSince(exhaustedAt) >= 79_990, "Recovery deferral should last until the rate limit reset.")
        }
        expect(recordedSleeps.allSatisfy { $0 <= 30 }, "Recovery fetch must never sleep past RetryPolicy.maxDelay.")
        MockWhoopURLProtocol.rateLimitHeaders = [:]

        MockWhoopURLProtocol.userBody = ["user": ["id": 1e19]]
        do {
            _ = try await client.fetchCurrentUser()
            fatalError("A user ID beyond Int64 should throw.")
        } catch is WhoopPayloadError {}
        MockWhoopURLProtocol.userBody = nil

        MockWhoopURLProtocol.clearRequests()
        MockWhoopURLProtocol.cyclesReturnsEmpty = true
        let probe = try await client.probeRecoveryValues()
        let probeRequests = MockWhoopURLProtocol.requests.filter { $0.path == "/core-details-bff/v0/cycles/details" }
        expect(probeRequests.count == 1, "Value diagnostic should make a single last-seven-days request.")
        expect(!probe.contains("2026-09-13"), "Value diagnostic must not ship personal reference values.")
        expect(!probe.contains("December"), "Value diagnostic must not reference a hard-coded start month.")
        expect(probeRequests.allSatisfy { $0.query["limit"] == "50" && $0.headers["Authorization"] == "Bearer fresh-access" }, "Diagnostic should remain bounded and reuse the current private session.")
        expect(probe.contains("empty window does not prove the end"), "An empty window must not imply historical completion.")
        expect(!MockWhoopURLProtocol.requests.contains { $0.path.contains("deep-dive") || $0.path.contains("sleep-events") || $0.path.contains("metrics") }, "Recovery diagnostic must not trigger legacy sleep/HR fallbacks.")

        MockWhoopURLProtocol.clearRequests()
        let recoveryRecords = try await client.fetchRecoveryCycleRecords(userID: user.id, window: TimeRange(start: start, end: end))
        expect(recoveryRecords.isEmpty, "Dedicated recovery transport parses the same private cycles route.")
        expect(MockWhoopURLProtocol.requests.count == 1 && MockWhoopURLProtocol.requests[0].query["limit"] == "50", "Recovery fetch is bounded with no legacy fallbacks.")
        MockWhoopURLProtocol.cyclesStatusCode = 429
        MockWhoopURLProtocol.retryAfter = "120"
        let before = Date()
        do { _ = try await client.fetchRecoveryCycleRecords(userID: user.id, window: TimeRange(start: start, end: end)); fatalError("429 must fail safely") }
        catch let RecoverySyncError.rateLimited(date) {
            expect(date.timeIntervalSince(before) >= 119, "Retry-After seconds must become a deadline.")
        }
        let requestCount = MockWhoopURLProtocol.requests.count
        do { _ = try await client.fetchRecoveryCycleRecords(userID: user.id, window: TimeRange(start: start, end: end)); fatalError("Backoff must prevent request") }
        catch let RecoverySyncError.rateLimited(date) { expect(date > Date(), "Deadline remains active") }
        expect(MockWhoopURLProtocol.requests.count == requestCount, "429 backoff must not send another network request.")
        MockWhoopURLProtocol.cyclesStatusCode = 200
        MockWhoopURLProtocol.retryAfter = nil
        print("WhoopAPIClient smoke check passed (legacy API, recovery transport, Retry-After and no legacy fallback)")
    }

    private static func request(path: String) throws -> MockWhoopURLProtocol.RecordedRequest {
        guard let request = MockWhoopURLProtocol.requests.first(where: { $0.path == path }) else {
            throw SmokeError.missingRequest(path)
        }
        return request
    }

    private static func iso(_ value: String) -> Date {
        guard let date = WhoopDateCodec.date(from: value) else {
            fatalError("Invalid fixture date \(value).")
        }
        return date
    }

    private static func localDateString(for date: Date) -> String {
        let formatter = DateFormatter()
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = .current
        formatter.dateFormat = "yyyy-MM-dd"
        return formatter.string(from: date)
    }

    private static func expect(_ condition: @autoclosure () -> Bool, _ message: String) {
        guard condition() else {
            fatalError(message)
        }
    }
}

private final class InMemoryTokenStore: TokenStoring {
    var bundle: TokenBundle?

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

private final class MockWhoopURLProtocol: URLProtocol {
    struct RecordedRequest {
        var path: String
        var query: [String: String]
        var headers: [String: String]
        var body: [String: Any]
    }

    static var requests: [RecordedRequest] = []
    static var cyclesReturnsEmpty = false
    static var cyclesPerDay = false
    static var cyclesStatusCode = 200
    static var retryAfter: String?
    static var deepDiveSleepStatusCode = 200
    static var heartRateStatusCode = 200
    static var heartRateErrorBody: [String: Any] = ["error": "heart-rate unavailable"]
    static var userStatusCode = 200
    static var userBody: [String: Any]?
    static var rateLimitHeaders: [String: String] = [:]
    private static var staleUserRequestCount = 0
    private static var staleUserStatusCode = 401

    static func reset() {
        requests.removeAll()
        cyclesReturnsEmpty = false
        cyclesPerDay = false
        deepDiveSleepStatusCode = 200
        heartRateStatusCode = 200
        heartRateErrorBody = ["error": "heart-rate unavailable"]
        staleUserRequestCount = 0
        staleUserStatusCode = 401
    }

    static func clearRequests() {
        requests.removeAll()
    }

    static func prepareStaleUser(status: Int) {
        staleUserRequestCount = 0
        staleUserStatusCode = status
    }

    override class func canInit(with request: URLRequest) -> Bool {
        request.url?.host == "api.prod.whoop.com"
    }

    override class func canonicalRequest(for request: URLRequest) -> URLRequest {
        request
    }

    override func startLoading() {
        do {
            guard let url = request.url else {
                throw SmokeError.invalidRequest
            }
            let bodyData = try requestBodyData()
            let body = bodyData.isEmpty
                ? [:]
                : (try JSONSerialization.jsonObject(with: bodyData, options: []) as? [String: Any] ?? [:])
            let query = URLComponents(url: url, resolvingAgainstBaseURL: false)?
                .queryItems?
                .reduce(into: [String: String]()) { partial, item in
                    partial[item.name] = item.value
                } ?? [:]

            let recorded = RecordedRequest(
                path: url.path,
                query: query,
                headers: request.allHTTPHeaderFields ?? [:],
                body: body
            )
            MockWhoopURLProtocol.requests.append(recorded)

            let response = try response(for: recorded)
            let responseData = try JSONSerialization.data(withJSONObject: response.body, options: [])
            let http = HTTPURLResponse(
                url: url,
                statusCode: response.status,
                httpVersion: "HTTP/1.1",
                headerFields: ["Content-Type": "application/json"].merging(Self.retryAfter.map { ["Retry-After": $0] } ?? [:]) { _, new in new }.merging(Self.rateLimitHeaders) { _, new in new }
            )!
            client?.urlProtocol(self, didReceive: http, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: responseData)
            client?.urlProtocolDidFinishLoading(self)
        } catch {
            fputs("Mock WHOOP URLProtocol error: \(error.localizedDescription)\n", stderr)
            client?.urlProtocol(self, didFailWithError: error)
        }
    }

    override func stopLoading() {}

    private func response(for request: RecordedRequest) throws -> (status: Int, body: [String: Any]) {
        if request.path == "/auth-service/v3/whoop" || request.path == "/auth-service/v3/whoop/" {
            return (
                200,
                [
                    "AuthenticationResult": [
                        "AccessToken": "fresh-access",
                        "IdToken": "fresh-id",
                        "ExpiresIn": 3_600,
                        "TokenType": "Bearer"
                    ]
                ]
            )
        }

        if request.path == "/auth-service/v2/user" {
            if request.headers["Authorization"] == "Bearer stale-access" && Self.staleUserRequestCount == 0 {
                Self.staleUserRequestCount += 1
                return (Self.staleUserStatusCode, ["error": "expired"])
            }
            if Self.userStatusCode != 200 { return (Self.userStatusCode, ["error": "rate-limited"]) }
            return (200, Self.userBody ?? ["user": ["id": 98_765]])
        }

        if request.path == "/core-details-bff/v0/cycles/details" {
            if Self.cyclesStatusCode != 200 { return (Self.cyclesStatusCode, ["error": "rate-limited"]) }
            if Self.cyclesReturnsEmpty {
                return (200, ["records": []])
            }
            if Self.cyclesPerDay,
               let start = request.query["startTime"].flatMap(WhoopDateCodec.date(from:)),
               let end = request.query["endTime"].flatMap(WhoopDateCodec.date(from:)) {
                var records: [[String: Any]] = []
                var day = start
                while day < end, records.count < 50 {
                    let id = WhoopDateCodec.isoString(day)
                    records.append([
                        "cycle": ["id": "cycle-\(id)"],
                        "sleeps": [["activity_id": "sleep-\(id)", "updated_at": id, "is_nap": false]]
                    ])
                    day = day.addingTimeInterval(86_400)
                }
                return (200, ["records": records])
            }
            return (
                200,
                [
                    "records": [
                        [
                            "cycle": ["id": "cycle-api-1"],
                            "sleeps": [
                                [
                                    "activity_id": "sleep-api-1",
                                    "updated_at": "2026-07-12T09:00:00.000Z",
                                    "is_nap": false
                                ]
                            ]
                        ]
                    ]
                ]
            )
        }

        if request.path == "/sleep-service/v1/sleep-events" {
            return (
                200,
                [
                    "events": [
                        [
                            "type": "LIGHT",
                            "during": "['2026-07-12T00:00:00.000Z','2026-07-12T00:15:00.000Z')"
                        ],
                        [
                            "type": "REM",
                            "during": "['2026-07-12T00:15:00.000Z','2026-07-12T00:30:00.000Z')"
                        ],
                        [
                            "type": "DISTURBANCES",
                            "during": "['2026-07-12T00:16:00.000Z','2026-07-12T00:16:30.000Z')"
                        ]
                    ]
                ]
            )
        }

        if request.path == "/home-service/v1/deep-dive/sleep" {
            if Self.deepDiveSleepStatusCode != 200 {
                return (Self.deepDiveSleepStatusCode, ["error": "deep-dive unavailable"])
            }
            return (
                200,
                [
                    "started_at": "2026-07-12T23:38:00.000+02:00",
                    "ended_at": "2026-07-13T00:08:00.000+02:00",
                    "hypnogram": [
                        [
                            "stage": "LIGHT",
                            "started_at": "2026-07-12T23:38:00.000+02:00",
                            "ended_at": "2026-07-12T23:48:00.000+02:00"
                        ],
                        [
                            "stage": "SWS",
                            "started_at": "2026-07-12T23:48:00.000+02:00",
                            "ended_at": "2026-07-12T23:58:00.000+02:00"
                        ],
                        [
                            "stage": "AWAKE",
                            "started_at": "2026-07-12T23:58:00.000+02:00",
                            "ended_at": "2026-07-13T00:08:00.000+02:00"
                        ]
                    ]
                ]
            )
        }

        if request.path == "/metrics-service/v1/metrics/user/98765" {
            if Self.heartRateStatusCode != 200 {
                return (Self.heartRateStatusCode, Self.heartRateErrorBody)
            }
            return (
                200,
                [
                    "values": [
                        ["time": "2026-07-12T00:00:00.000Z", "data": 60],
                        ["time": "2026-07-12T00:00:06.000Z", "data": 61]
                    ]
                ]
            )
        }

        fputs("Unhandled mock WHOOP path: \(request.path)\n", stderr)
        throw SmokeError.missingRequest(request.path)
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

private enum SmokeError: Error, LocalizedError {
    case invalidRequest
    case missingRequest(String)

    var errorDescription: String? {
        switch self {
        case .invalidRequest:
            return "Invalid mock request."
        case let .missingRequest(path):
            return "Missing mock request for \(path)."
        }
    }
}
