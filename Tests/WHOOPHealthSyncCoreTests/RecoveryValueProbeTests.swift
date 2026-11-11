import XCTest
@testable import WHOOPHealthSyncCore

final class RecoveryValueProbeTests: XCTestCase {
    private func payload(value: Any = 48.123456, activity: String = "private-sleep-id", duplicate: Bool = false) -> [String: Any] {
        let sleep: [String: Any] = ["activity_id": activity, "is_nap": false,
            "during": "[\"2026-09-14T22:30:00Z\",\"2026-09-15T06:00:00Z\")", "timezone_offset": "+02:00"]
        return ["next_token": "secret-pagination-token", "email": "private@example.invalid", "records": [[
            "cycle": ["id": 987654321, "user_id": 123456789],
            "recovery": ["user_id": 123456789, "activity_id": "private-sleep-id", "hrv_rmssd": value,
                "state": "complete", "calibrating": false, "updated_at": "2026-09-15T07:00:00Z"],
            "sleeps": duplicate ? [sleep, sleep] : [sleep]
        ]]]
    }
    func testValuePrecisionAndSleepOffsetWithoutIdentifiersOrTokens() {
        let output = WhoopRecoveryValueProbe.report(of: payload(), expectedUserID: "123456789")
        XCTAssertTrue(output.contains("HRV_API=48.123456"))
        XCTAssertTrue(output.contains("end=2026-09-15 08:00:00 +0200"))
        XCTAssertTrue(output.contains("account=matches")); XCTAssertTrue(output.contains("sleep_link=unique"))
        for secret in ["123456789", "987654321", "private-sleep-id", "private@example.invalid", "secret-pagination-token"] {
            XCTAssertFalse(output.contains(secret))
        }
        XCTAssertTrue(output.contains("HRV_API in seconds"))
    }
    func testJSONBooleanIsNotAnHRVMeasurement() throws {
        let json = try JSONSerialization.jsonObject(with: JSONSerialization.data(withJSONObject: payload(value: true)))
        let output = WhoopRecoveryValueProbe.report(of: json, expectedUserID: "123456789")
        XCTAssertTrue(output.contains("HRV_API=invalid/null")); XCTAssertFalse(output.contains("HRV_API=1"))
        XCTAssertTrue(output.contains("calibrating=no"))
    }
    func testWrongAccountOrAmbiguousSleepDoesNotProduceValidatedAssociation() {
        let mismatch = WhoopRecoveryValueProbe.report(of: payload(activity: "different-private-id"), expectedUserID: "other-user")
        XCTAssertTrue(mismatch.contains("account=NOT VERIFIED")); XCTAssertTrue(mismatch.contains("end=unrecognized"))
        let duplicate = WhoopRecoveryValueProbe.report(of: payload(duplicate: true), expectedUserID: "123456789")
        XCTAssertTrue(duplicate.contains("sleep_link=missing/ambiguous")); XCTAssertTrue(duplicate.contains("end=unrecognized"))
    }
    func testUnknownPayloadAndEmptyWindowAreNotHistoricalCompletion() {
        XCTAssertTrue(WhoopRecoveryValueProbe.report(of: ["error": "secret"], expectedUserID: "1").contains("records[] missing"))
        let output = WhoopRecoveryValueProbe.report(of: ["records": []], expectedUserID: "1")
        XCTAssertTrue(output.contains("empty window does not prove the end"))
    }
    func testOutputIsBoundedAndRejectsNonFiniteValues() {
        var root = payload(value: Double.infinity)
        let record = (root["records"] as! [[String: Any]])[0]
        root["records"] = Array(repeating: record, count: 100)
        let output = WhoopRecoveryValueProbe.report(of: root, expectedUserID: "123456789", maxRows: 1)
        XCTAssertTrue(output.contains("Output limited to 1 rows")); XCTAssertFalse(output.contains("Row 2:"))
        XCTAssertTrue(output.contains("HRV_API=invalid/null"))
    }
}
