import Foundation
import WHOOPHealthSyncCore

struct SyncStateRecord: Codable, Equatable {
    var key: String
    var dateValue: Date?
    var intValue: Int?
    var stringValue: String?
    var updatedAt: Date

    init(key: String, dateValue: Date? = nil, intValue: Int? = nil, stringValue: String? = nil, updatedAt: Date = Date()) {
        self.key = key
        self.dateValue = dateValue
        self.intValue = intValue
        self.stringValue = stringValue
        self.updatedAt = updatedAt
    }
}

struct SleepSyncRecord: Codable, Equatable {
    var whoopSleepID: String
    var sourceUpdatedAt: Date?
    var start: Date
    var end: Date
    var isNap: Bool
    var fingerprint: String
    var syncVersion: Int
    var lastProcessedAt: Date
    var lastResult: String

    init(
        whoopSleepID: String,
        sourceUpdatedAt: Date?,
        start: Date,
        end: Date,
        isNap: Bool,
        fingerprint: String,
        syncVersion: Int,
        lastProcessedAt: Date,
        lastResult: String
    ) {
        self.whoopSleepID = whoopSleepID
        self.sourceUpdatedAt = sourceUpdatedAt
        self.start = start
        self.end = end
        self.isNap = isNap
        self.fingerprint = fingerprint
        self.syncVersion = syncVersion
        self.lastProcessedAt = lastProcessedAt
        self.lastResult = lastResult
    }
}

enum SyncRunStatus: String, Codable {
    case running, success, partial, failed, cancelled, unknown
}

struct SyncRunRecord: Codable, Equatable, Identifiable {
    var id: UUID
    var startedAt: Date
    var finishedAt: Date?
    var status: SyncRunStatus
    var heartRateWindowStart: Date?
    var heartRateWindowEnd: Date?
    var sleepWindowStart: Date?
    var sleepWindowEnd: Date?
    var sleepsDownloaded: Int
    var sleepsWritten: Int
    var sleepsUnchanged: Int
    var sleepsRevised: Int
    var sleepsDiscardedOutOfWindow: Int
    var stagesWritten: Int
    var stagesSkipped: Int
    var stagesRemoved: Int
    var heartRateDownloaded: Int
    var heartRateDiscardedOutOfWindow: Int
    var heartRateWritten: Int
    var heartRateSkipped: Int
    var heartRateRemoved: Int
    var effectiveHeartRateResolution: Int?
    var elapsedSeconds: Double
    var recovery: RecoverySyncSummary
    var errorsText: String
    // Stored as raw strings because the core SyncDataResult enum is not Codable.
    private var sleepResultValue: String
    private var heartRateResultValue: String

    var sleepResult: SyncDataResult {
        get { SyncDataResult(rawValue: sleepResultValue) ?? .notAttempted }
        set { sleepResultValue = newValue.rawValue }
    }

    var heartRateResult: SyncDataResult {
        get { SyncDataResult(rawValue: heartRateResultValue) ?? .notAttempted }
        set { heartRateResultValue = newValue.rawValue }
    }

    private enum CodingKeys: String, CodingKey {
        case id
        case startedAt
        case finishedAt
        case status
        case heartRateWindowStart
        case heartRateWindowEnd
        case sleepWindowStart
        case sleepWindowEnd
        case sleepsDownloaded
        case sleepsWritten
        case sleepsUnchanged
        case sleepsRevised
        case sleepsDiscardedOutOfWindow
        case stagesWritten
        case stagesSkipped
        case stagesRemoved
        case heartRateDownloaded
        case heartRateDiscardedOutOfWindow
        case heartRateWritten
        case heartRateSkipped
        case heartRateRemoved
        case effectiveHeartRateResolution
        case elapsedSeconds
        case recovery
        case errorsText
        case sleepResultValue = "sleepResult"
        case heartRateResultValue = "heartRateResult"
    }

    init(startedAt: Date) {
        self.id = UUID()
        self.startedAt = startedAt
        self.status = .running
        self.sleepsDownloaded = 0
        self.sleepsWritten = 0
        self.sleepsUnchanged = 0
        self.sleepsRevised = 0
        self.sleepsDiscardedOutOfWindow = 0
        self.stagesWritten = 0
        self.stagesSkipped = 0
        self.stagesRemoved = 0
        self.heartRateDownloaded = 0
        self.heartRateDiscardedOutOfWindow = 0
        self.heartRateWritten = 0
        self.heartRateSkipped = 0
        self.heartRateRemoved = 0
        self.effectiveHeartRateResolution = nil
        self.elapsedSeconds = 0
        self.recovery = RecoverySyncSummary()
        self.errorsText = ""
        self.sleepResultValue = SyncDataResult.notAttempted.rawValue
        self.heartRateResultValue = SyncDataResult.notAttempted.rawValue
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.id = try container.decode(UUID.self, forKey: .id)
        self.startedAt = try container.decode(Date.self, forKey: .startedAt)
        self.finishedAt = try container.decodeIfPresent(Date.self, forKey: .finishedAt)
        self.status = try container.decodeIfPresent(String.self, forKey: .status).flatMap(SyncRunStatus.init(rawValue:)) ?? .unknown
        self.heartRateWindowStart = try container.decodeIfPresent(Date.self, forKey: .heartRateWindowStart)
        self.heartRateWindowEnd = try container.decodeIfPresent(Date.self, forKey: .heartRateWindowEnd)
        self.sleepWindowStart = try container.decodeIfPresent(Date.self, forKey: .sleepWindowStart)
        self.sleepWindowEnd = try container.decodeIfPresent(Date.self, forKey: .sleepWindowEnd)
        self.sleepsDownloaded = try container.decodeIfPresent(Int.self, forKey: .sleepsDownloaded) ?? 0
        self.sleepsWritten = try container.decodeIfPresent(Int.self, forKey: .sleepsWritten) ?? 0
        self.sleepsUnchanged = try container.decodeIfPresent(Int.self, forKey: .sleepsUnchanged) ?? 0
        self.sleepsRevised = try container.decodeIfPresent(Int.self, forKey: .sleepsRevised) ?? 0
        self.sleepsDiscardedOutOfWindow = try container.decodeIfPresent(Int.self, forKey: .sleepsDiscardedOutOfWindow) ?? 0
        self.stagesWritten = try container.decodeIfPresent(Int.self, forKey: .stagesWritten) ?? 0
        self.stagesSkipped = try container.decodeIfPresent(Int.self, forKey: .stagesSkipped) ?? 0
        self.stagesRemoved = try container.decodeIfPresent(Int.self, forKey: .stagesRemoved) ?? 0
        self.heartRateDownloaded = try container.decodeIfPresent(Int.self, forKey: .heartRateDownloaded) ?? 0
        self.heartRateDiscardedOutOfWindow = try container.decodeIfPresent(Int.self, forKey: .heartRateDiscardedOutOfWindow) ?? 0
        self.heartRateWritten = try container.decodeIfPresent(Int.self, forKey: .heartRateWritten) ?? 0
        self.heartRateSkipped = try container.decodeIfPresent(Int.self, forKey: .heartRateSkipped) ?? 0
        self.heartRateRemoved = try container.decodeIfPresent(Int.self, forKey: .heartRateRemoved) ?? 0
        self.effectiveHeartRateResolution = try container.decodeIfPresent(Int.self, forKey: .effectiveHeartRateResolution)
        self.elapsedSeconds = try container.decodeIfPresent(Double.self, forKey: .elapsedSeconds) ?? 0
        self.recovery = try container.decodeIfPresent(RecoverySyncSummary.self, forKey: .recovery) ?? RecoverySyncSummary()
        self.errorsText = try container.decodeIfPresent(String.self, forKey: .errorsText) ?? ""
        self.sleepResultValue = Self.resultValue(try container.decodeIfPresent(String.self, forKey: .sleepResultValue))
        self.heartRateResultValue = Self.resultValue(try container.decodeIfPresent(String.self, forKey: .heartRateResultValue))
    }

    private static func resultValue(_ raw: String?) -> String {
        (raw.flatMap(SyncDataResult.init(rawValue:)) ?? .notAttempted).rawValue
    }
}

extension SyncSummary {
    init(record: SyncRunRecord) {
        self.init()
        sleepResult = record.sleepResult
        heartRateResult = record.heartRateResult
        recovery = record.recovery
        sleepsDownloaded = record.sleepsDownloaded
        sleepsWritten = record.sleepsWritten
        sleepsUnchanged = record.sleepsUnchanged
        sleepsRevised = record.sleepsRevised
        sleepsDiscardedOutOfWindow = record.sleepsDiscardedOutOfWindow
        stagesWritten = record.stagesWritten
        stagesSkipped = record.stagesSkipped
        stagesRemoved = record.stagesRemoved
        heartRateDownloaded = record.heartRateDownloaded
        heartRateWritten = record.heartRateWritten
        heartRateSkipped = record.heartRateSkipped
        heartRateRemoved = record.heartRateRemoved
        heartRateDiscardedOutOfWindow = record.heartRateDiscardedOutOfWindow
        effectiveHeartRateResolution = record.effectiveHeartRateResolution
        heartRateWindowStart = record.heartRateWindowStart
        heartRateWindowEnd = record.heartRateWindowEnd
        sleepQueryWindowStart = record.sleepWindowStart
        sleepQueryWindowEnd = record.sleepWindowEnd
        elapsedSeconds = record.elapsedSeconds
        errors = record.errorsText.isEmpty ? [] : record.errorsText.components(separatedBy: "\n")
    }
}

struct SyncEventRecord: Codable, Equatable, Identifiable {
    var id: UUID
    var runID: UUID?
    var timestamp: Date
    var level: String
    var category: String
    var message: String

    init(
        id: UUID = UUID(),
        runID: UUID?,
        timestamp: Date = Date(),
        level: String,
        category: String,
        message: String
    ) {
        self.id = id
        self.runID = runID
        self.timestamp = timestamp
        self.level = level
        self.category = category
        self.message = message
    }
}

struct SyncStoreSnapshot: Codable, Equatable {
    var schemaVersion: Int = 2
    var recovery: RecoverySyncState = RecoverySyncState()
    var linkedAccountKey: String?
    var states: [String: SyncStateRecord] = [:]
    var sleepRecords: [String: SleepSyncRecord] = [:]
    var runs: [SyncRunRecord] = []
    var events: [SyncEventRecord] = []

    static let empty = SyncStoreSnapshot()

    private enum CodingKeys: String, CodingKey {
        case schemaVersion, recovery, linkedAccountKey
        case states
        case sleepRecords
        case runs
        case events
    }

    init(
        states: [String: SyncStateRecord] = [:],
        sleepRecords: [String: SleepSyncRecord] = [:],
        runs: [SyncRunRecord] = [],
        events: [SyncEventRecord] = []
    ) {
        self.states = states
        self.sleepRecords = sleepRecords
        self.runs = runs
        self.events = events
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        guard container.contains(.states) || container.contains(.runs) || container.contains(.sleepRecords) else {
            throw SyncRepositoryError.storeUnavailable
        }
        let version = try container.decodeIfPresent(Int.self, forKey: .schemaVersion) ?? 1
        guard (1...2).contains(version) else { throw SyncRepositoryError.unsupportedSchema }
        self.schemaVersion = 2
        self.recovery = try container.decodeIfPresent(RecoverySyncState.self, forKey: .recovery) ?? RecoverySyncState()
        self.linkedAccountKey = try container.decodeIfPresent(String.self, forKey: .linkedAccountKey)
        self.states = try container.decodeIfPresent([String: SyncStateRecord].self, forKey: .states) ?? [:]
        self.sleepRecords = try container.decodeIfPresent([String: SleepSyncRecord].self, forKey: .sleepRecords) ?? [:]
        self.runs = try container.decodeIfPresent([SyncRunRecord].self, forKey: .runs) ?? []
        self.events = try container.decodeIfPresent([SyncEventRecord].self, forKey: .events) ?? []
    }
}

struct SyncDiagnostics: Equatable {
    var deferredSleepWindow: TimeRange? = nil
    var deferredHeartRateWindow: TimeRange? = nil
    var lastHeartRateCheckpoint: Date?
    var lastSleepCheckpoint: Date?
    var heartRateResolution: Int?
    var lastRunStartedAt: Date?
    var lastRunFinishedAt: Date?
    var lastRunStatus: SyncRunStatus?
    var lastRunErrorsText: String
    var recordedSleepCount: Int
    var recentEvents: [SyncEventRecord]

    static let empty = SyncDiagnostics(
        lastHeartRateCheckpoint: nil,
        lastSleepCheckpoint: nil,
        heartRateResolution: nil,
        lastRunStartedAt: nil,
        lastRunFinishedAt: nil,
        lastRunStatus: nil,
        lastRunErrorsText: "",
        recordedSleepCount: 0,
        recentEvents: []
    )
}
