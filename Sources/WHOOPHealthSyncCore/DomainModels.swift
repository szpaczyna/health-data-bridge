import Foundation

public enum SleepStage: String, Codable, CaseIterable, Sendable {
    case awake
    case core
    case deep
    case rem
}

public struct TimeRange: Codable, Equatable, Hashable, Sendable {
    public var start: Date
    public var end: Date

    public init(start: Date, end: Date) {
        self.start = start
        self.end = end
    }

    public var hasPositiveDuration: Bool {
        start < end
    }

    public func overlaps(_ other: TimeRange) -> Bool {
        start < other.end && other.start < end
    }

    public func intersection(with other: TimeRange) -> TimeRange? {
        let lower = max(start, other.start)
        let upper = min(end, other.end)
        guard lower < upper else { return nil }
        return TimeRange(start: lower, end: upper)
    }
}

public struct SleepStageInterval: Codable, Equatable, Hashable, Sendable {
    public var range: TimeRange
    public var stage: SleepStage

    public init(start: Date, end: Date, stage: SleepStage) {
        self.range = TimeRange(start: start, end: end)
        self.stage = stage
    }

    public init(range: TimeRange, stage: SleepStage) {
        self.range = range
        self.stage = stage
    }
}

public struct SleepSession: Codable, Equatable, Sendable {
    public var whoopSleepID: String
    public var sourceUpdatedAt: Date?
    public var start: Date
    public var end: Date
    public var timezoneOffsetSeconds: Int?
    public var isNap: Bool
    public var stages: [SleepStageInterval]

    public init(
        whoopSleepID: String,
        sourceUpdatedAt: Date?,
        start: Date,
        end: Date,
        timezoneOffsetSeconds: Int?,
        isNap: Bool,
        stages: [SleepStageInterval]
    ) {
        self.whoopSleepID = whoopSleepID
        self.sourceUpdatedAt = sourceUpdatedAt
        self.start = start
        self.end = end
        self.timezoneOffsetSeconds = timezoneOffsetSeconds
        self.isNap = isNap
        self.stages = stages
    }
}

public struct HeartRatePoint: Codable, Equatable, Hashable, Sendable {
    public var timestamp: Date
    public var bpm: Double
    public var sourceStepSeconds: Int

    public init(timestamp: Date, bpm: Double, sourceStepSeconds: Int) {
        self.timestamp = timestamp
        self.bpm = bpm
        self.sourceStepSeconds = sourceStepSeconds
    }
}

public enum SyncDataResult: String, Equatable, Sendable {
    case notAttempted = "Not checked"
    case noData = "No data received"
    case existing = "Data already existed"
    case updated = "Samples added or updated"
    case pendingAccess = "Pending access check"
    case failed = "Could not finish; retry required"

    var priority: Int {
        switch self {
        case .notAttempted: return 0
        case .noData: return 1
        case .existing: return 2
        case .updated: return 3
        case .failed: return 4
        case .pendingAccess: return 5
        }
    }
}

public struct SyncSummary: Equatable, Sendable {
    public var sleepResult: SyncDataResult = .notAttempted
    public var heartRateResult: SyncDataResult = .notAttempted
    public var recovery = RecoverySyncSummary()
    public var sleepsDownloaded: Int = 0
    public var sleepsWritten: Int = 0
    public var sleepsUnchanged: Int = 0
    public var sleepsRevised: Int = 0
    public var sleepsDiscardedOutOfWindow: Int = 0
    public var stagesWritten: Int = 0
    public var stagesSkipped: Int = 0
    public var stagesRemoved: Int = 0
    public var heartRateDownloaded: Int = 0
    public var heartRateWritten: Int = 0
    public var heartRateSkipped: Int = 0
    public var heartRateRemoved: Int = 0
    public var heartRateDiscardedOutOfWindow: Int = 0
    public var effectiveHeartRateResolution: Int?
    public var heartRateWindowStart: Date?
    public var heartRateWindowEnd: Date?
    public var sleepQueryWindowStart: Date?
    public var sleepQueryWindowEnd: Date?
    public var elapsedSeconds: Double = 0
    public var errors: [String] = []

    public init() {}

    /// A transport success alone cannot certify every selected data phase.
    public var hasIncompleteResults: Bool {
        guard errors.isEmpty else { return true }
        let confirmed: [SyncDataResult] = [.updated, .existing, .noData]
        guard confirmed.contains(sleepResult), confirmed.contains(heartRateResult) else { return true }
        return !recovery.isSettled
    }

    public mutating func merge(_ other: SyncSummary) {
        if other.sleepResult.priority > sleepResult.priority { sleepResult = other.sleepResult }
        if other.heartRateResult.priority > heartRateResult.priority { heartRateResult = other.heartRateResult }
        if other.recovery.status != .disabled { recovery = other.recovery }
        sleepsDownloaded += other.sleepsDownloaded
        sleepsWritten += other.sleepsWritten
        sleepsUnchanged += other.sleepsUnchanged
        sleepsRevised += other.sleepsRevised
        sleepsDiscardedOutOfWindow += other.sleepsDiscardedOutOfWindow
        stagesWritten += other.stagesWritten
        stagesSkipped += other.stagesSkipped
        stagesRemoved += other.stagesRemoved
        heartRateDownloaded += other.heartRateDownloaded
        heartRateWritten += other.heartRateWritten
        heartRateSkipped += other.heartRateSkipped
        heartRateRemoved += other.heartRateRemoved
        heartRateDiscardedOutOfWindow += other.heartRateDiscardedOutOfWindow
        effectiveHeartRateResolution = other.effectiveHeartRateResolution ?? effectiveHeartRateResolution
        heartRateWindowStart = other.heartRateWindowStart ?? heartRateWindowStart
        heartRateWindowEnd = other.heartRateWindowEnd ?? heartRateWindowEnd
        sleepQueryWindowStart = other.sleepQueryWindowStart ?? sleepQueryWindowStart
        sleepQueryWindowEnd = other.sleepQueryWindowEnd ?? sleepQueryWindowEnd
        elapsedSeconds += other.elapsedSeconds
        errors.append(contentsOf: other.errors)
    }
}
