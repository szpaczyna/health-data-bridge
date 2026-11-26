import Foundation
import CryptoKit

public enum RecoveryScoreState: String, Codable, Sendable {
    case scored = "SCORED", pending = "PENDING_SCORE", unscorable = "UNSCORABLE"
}

/// Normalized provider output. The live provider must establish these semantics in G2.
public struct WhoopRecovery: Equatable, Sendable {
    public var accountKey: String
    public var cycleID: String
    public var sleepID: String
    public var sleepRange: TimeRange
    public var sourceTimeZoneID: String
    public var milliseconds: Double?
    public var scoreState: RecoveryScoreState
    public var updatedAt: Date
    public var userCalibrating: Bool
    public var adapterVersion: String
    public init(accountKey: String, cycleID: String, sleepID: String, sleepRange: TimeRange,
                sourceTimeZoneID: String, milliseconds: Double?, scoreState: RecoveryScoreState,
                updatedAt: Date, userCalibrating: Bool = false, adapterVersion: String = "recovery-v1") {
        self.accountKey = accountKey; self.cycleID = cycleID; self.sleepID = sleepID
        self.sleepRange = sleepRange; self.sourceTimeZoneID = sourceTimeZoneID
        self.milliseconds = milliseconds; self.scoreState = scoreState; self.updatedAt = updatedAt
        self.userCalibrating = userCalibrating; self.adapterVersion = adapterVersion
    }
    public var identifier: String { "whoop-rmssd:\(accountKey):\(cycleID)" }
    public var representedDate: Date { sleepRange.end }
    public func coverageWindow() throws -> TimeRange {
        guard sleepRange.hasPositiveDuration, let zone = TimeZone(identifier: sourceTimeZoneID) else {
            throw RecoverySyncError.invalidTemporalAssociation
        }
        var calendar = Calendar(identifier: .gregorian); calendar.timeZone = zone
        let dayStart = calendar.startOfDay(for: sleepRange.end)
        guard let dayEnd = calendar.date(byAdding: .day, value: 1, to: dayStart) else {
            throw RecoverySyncError.invalidTemporalAssociation
        }
        return TimeRange(start: min(sleepRange.start, dayStart), end: max(sleepRange.end, dayEnd))
    }
    public func fingerprint() throws -> String {
        guard !accountKey.isEmpty, !accountKey.contains(":"), !cycleID.isEmpty, !cycleID.contains(":"), !sleepID.isEmpty,
              let value = milliseconds, value.isFinite, value > 0, scoreState == .scored,
              !userCalibrating else { throw RecoverySyncError.invalidRecord }
        _ = try coverageWindow()
        // IEEE-754 bit patterns preserve precision and do not depend on locale or hash seed.
        let fields = [accountKey, cycleID, sleepID, String(value.bitPattern),
                      String(sleepRange.start.timeIntervalSince1970.bitPattern),
                      String(sleepRange.end.timeIntervalSince1970.bitPattern), sourceTimeZoneID,
                      "RMSSD", "ms", "sleep-end", adapterVersion]
        let bytes = try JSONEncoder().encode(fields)
        return SHA256.hash(data: bytes).map { String(format: "%02x", $0) }.joined()
    }
    public static func pseudonymousAccountKey(userID: String) -> String {
        SHA256.hash(data: Data("WHOOPHealthSync-account:\(userID)".utf8))
            .map { String(format: "%02x", $0) }.joined()
    }
}

public enum HealthReadAccess: Equatable, Sendable {
    case unknown
    /// Explicit personal setup confirmation; not an inferred HealthKit permission.
    case userConfirmedFullAccess
    case nativeExporter(bundle: String)
    case limited(since: Date)
    /// Evidence of visible external data; this is not a guarantee of permission.
    case externallyVisible
    public func covers(_ range: TimeRange) -> Bool {
        switch self {
        case .unknown: return false
        case let .limited(date): return range.start >= date
        case .externallyVisible, .userConfirmedFullAccess: return true
        case .nativeExporter: return false
        }
    }
}

public struct ExistingRecoverySample: Equatable, Sendable {
    public var range: TimeRange
    public var sourceBundle: String
    public var method: String
    public var identifier: String?
    public var fingerprint: String?
    public var version: Int
    public var recognizedMetadata: Bool
    public init(range: TimeRange, sourceBundle: String, method: String = "RMSSD", identifier: String? = nil,
                fingerprint: String? = nil, version: Int = 0, recognizedMetadata: Bool = false) {
        self.range = range; self.sourceBundle = sourceBundle; self.method = method
        self.identifier = identifier; self.fingerprint = fingerprint; self.version = version
        self.recognizedMetadata = recognizedMetadata
    }
    public func isOwned(appBundle: String) -> Bool {
        sourceBundle == appBundle && recognizedMetadata && method == "RMSSD"
            && identifier?.hasPrefix("whoop-rmssd:") == true
    }
}

public struct RecoverySyncRecord: Codable, Equatable, Sendable {
    public var identifier: String
    public var fingerprint: String
    public var version: Int
    public var sourceUpdatedAt: Date
    public var representedDate: Date
    public init(identifier: String, fingerprint: String, version: Int, sourceUpdatedAt: Date, representedDate: Date) {
        self.identifier = identifier; self.fingerprint = fingerprint; self.version = version
        self.sourceUpdatedAt = sourceUpdatedAt; self.representedDate = representedDate
    }
}
public struct RecoveryPendingOperation: Codable, Equatable, Sendable {
    public var identifier: String
    public var fingerprint: String
    public var version: Int
    public var sourceQueryRange: TimeRange?
    public init(identifier: String, fingerprint: String, version: Int, sourceQueryRange: TimeRange? = nil) {
        self.identifier = identifier; self.fingerprint = fingerprint; self.version = version; self.sourceQueryRange = sourceQueryRange
    }
}
public struct RecoveryPendingItem: Codable, Equatable, Sendable {
    public var cycleID: String
    public var firstDetectedAt: Date
    public var reason: String
    public var range: TimeRange?
    public init(cycleID: String, firstDetectedAt: Date, reason: String, range: TimeRange? = nil) {
        self.cycleID = cycleID; self.firstDetectedAt = firstDetectedAt; self.reason = reason; self.range = range
    }
    public func requiresManualReview(at now: Date) -> Bool {
        reason == "pending_score" && now.timeIntervalSince(firstDetectedAt) >= 30 * 86400
    }
}

public struct RecoverySyncState: Codable, Equatable, Sendable {
    public var enabled = false
    public var configured = false
    public var providerRetryNotBefore: Date?
    public var historyStartDate: Date?
    public var historyScopeLimited = false
    public var userConfirmedFullReadAccess = false
    public var accountKey: String?
    public var initialImportCutoff: Date?
    public var initialEnumerationComplete = false
    public var historicalCursor: String?
    public var historicalPagesConfirmed = 0
    public var confirmedCursorFingerprints: Set<String> = []
    public var oldestEnumeratedDate: Date?
    public var lastDiscoveryEnd: Date?
    public var records: [String: RecoverySyncRecord] = [:]
    public var pendingOperations: [String: RecoveryPendingOperation] = [:]
    public var pendingItems: [String: RecoveryPendingItem] = [:]
    public var officialWhoopBundle: String?
    public var pausedForNativeExport = false
    public init() {}
    private enum CodingKeys: String, CodingKey {
        case providerRetryNotBefore, historyStartDate, historyScopeLimited, userConfirmedFullReadAccess
        case enabled, configured, accountKey, initialImportCutoff, initialEnumerationComplete, historicalCursor, historicalPagesConfirmed, confirmedCursorFingerprints, oldestEnumeratedDate, lastDiscoveryEnd, records, pendingOperations, pendingItems, officialWhoopBundle, pausedForNativeExport
    }
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.providerRetryNotBefore = try c.decodeIfPresent(Date.self, forKey: .providerRetryNotBefore)
        self.historyStartDate = try c.decodeIfPresent(Date.self, forKey: .historyStartDate)
        self.historyScopeLimited = try c.decodeIfPresent(Bool.self, forKey: .historyScopeLimited) ?? false
        self.userConfirmedFullReadAccess = try c.decodeIfPresent(Bool.self, forKey: .userConfirmedFullReadAccess) ?? false
        self.enabled = try c.decodeIfPresent(Bool.self, forKey: .enabled) ?? false
        self.configured = try c.decodeIfPresent(Bool.self, forKey: .configured) ?? false
        self.accountKey = try c.decodeIfPresent(String.self, forKey: .accountKey)
        self.initialImportCutoff = try c.decodeIfPresent(Date.self, forKey: .initialImportCutoff)
        self.initialEnumerationComplete = try c.decodeIfPresent(Bool.self, forKey: .initialEnumerationComplete) ?? false
        self.historicalCursor = try c.decodeIfPresent(String.self, forKey: .historicalCursor)
        self.historicalPagesConfirmed = try c.decodeIfPresent(Int.self, forKey: .historicalPagesConfirmed) ?? 0
        self.confirmedCursorFingerprints = try c.decodeIfPresent(Set<String>.self, forKey: .confirmedCursorFingerprints) ?? []
        self.oldestEnumeratedDate = try c.decodeIfPresent(Date.self, forKey: .oldestEnumeratedDate)
        self.lastDiscoveryEnd = try c.decodeIfPresent(Date.self, forKey: .lastDiscoveryEnd)
        self.records = try c.decodeIfPresent([String: RecoverySyncRecord].self, forKey: .records) ?? [:]
        self.pendingOperations = try c.decodeIfPresent([String: RecoveryPendingOperation].self, forKey: .pendingOperations) ?? [:]
        self.pendingItems = try c.decodeIfPresent([String: RecoveryPendingItem].self, forKey: .pendingItems) ?? [:]
        self.officialWhoopBundle = try c.decodeIfPresent(String.self, forKey: .officialWhoopBundle)
        self.pausedForNativeExport = try c.decodeIfPresent(Bool.self, forKey: .pausedForNativeExport) ?? false
    }
    public var historicalResolved: Bool {
        initialEnumerationComplete && pendingItems.isEmpty && pendingOperations.isEmpty
    }
    public func recentWindow(now: Date) -> TimeRange {
        let recent = now.addingTimeInterval(-7 * 86400)
        return TimeRange(start: min(lastDiscoveryEnd ?? initialImportCutoff ?? recent, recent, now), end: now)
    }
}

public enum RecoveryFlowStatus: String, Codable, Sendable {
    case disabled, requiresIOS27, configurationPending, ready, importingHistory, historyPending
    case noData, skippedExternal, readUnverified, historyLimited, pausedNativeExport, completed, issues
    public var isSettled: Bool {
        switch self {
        case .disabled, .requiresIOS27, .pausedNativeExport, .completed, .historyLimited, .noData, .skippedExternal: true
        case .configurationPending, .ready, .importingHistory, .historyPending, .readUnverified, .issues: false
        }
    }
}
public struct RecoverySyncSummary: Codable, Equatable, Sendable {
    public var status: RecoveryFlowStatus = .disabled
    public var downloaded = 0, written = 0, revised = 0, unchanged = 0, skippedExternal = 0
    public var pending = 0, unscorable = 0, invalid = 0, deferredAccess = 0, pagesConfirmed = 0
    public var recentCompleted = false, historicalComplete = false
    public var isSettled: Bool { status.isSettled && pending == 0 && deferredAccess == 0 }
    public init() {}
}
public enum RecoverySyncError: Error, LocalizedError, Equatable {
    case rateLimited(until: Date)
    case unavailable, invalidRecord, invalidTemporalAssociation, accountMismatch, readUnverified
    case repeatedCursor, cursorExpired, unknownHistoryEnd, versionOverflow, providerContractUnverified
    public var errorDescription: String? {
        switch self {
        case let .rateLimited(date): return "WHOOP recovery rate limit; retry after " + WhoopDateCodec.isoString(date)
        case .unavailable: return "Recovery HRV requires a validated iOS 27 build."
        case .invalidRecord: return "Recovery contract or RMSSD value is invalid."
        case .invalidTemporalAssociation: return "Recovery sleep association or source time zone is unverified."
        case .accountMismatch: return "WHOOP account differs from the account linked to local progress."
        case .readUnverified: return "External RMSSD read visibility could not be verified."
        case .cursorExpired: return "Recovery cursor expired; enumeration will restart safely with the fixed cutoff."
        case .repeatedCursor: return "Recovery pagination repeated a cursor; history remains pending."
        case .unknownHistoryEnd: return "Provider has not demonstrated the end of recovery history."
        case .versionOverflow: return "Recovery sync version cannot be incremented safely."
        case .providerContractUnverified: return "Recovery provider contract has not passed G2 validation."
        }
    }
}
