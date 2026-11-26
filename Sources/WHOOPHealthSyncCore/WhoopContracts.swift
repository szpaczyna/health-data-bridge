import Foundation

public struct WhoopUser: Equatable, Sendable {
    public var id: String

    public init(id: String) {
        self.id = id
    }
}

public struct WhoopSleepActivity: Equatable, Hashable, Sendable {
    public var activityID: String
    public var sourceUpdatedAt: Date?
    public var isNap: Bool

    public init(activityID: String, sourceUpdatedAt: Date?, isNap: Bool) {
        self.activityID = activityID
        self.sourceUpdatedAt = sourceUpdatedAt
        self.isNap = isNap
    }
}

public enum WhoopDateCodec {
    private static let fractionalISO8601: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter
    }()

    private static let basicISO8601: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        return formatter
    }()

    public static func isoString(_ date: Date) -> String {
        fractionalISO8601.string(from: date)
    }

    public static func date(from value: Any?) -> Date? {
        if let date = value as? Date {
            return date
        }
        if let seconds = value as? Double, seconds > 1_000_000_000 {
            return date(fromEpochNumber: seconds)
        }
        if let seconds = value as? Int, seconds > 1_000_000_000 {
            return date(fromEpochNumber: Double(seconds))
        }
        guard let string = value as? String else {
            return nil
        }
        let trimmed = string.trimmingCharacters(in: .whitespacesAndNewlines)
        if let numeric = Double(trimmed), numeric > 1_000_000_000 {
            return date(fromEpochNumber: numeric)
        }
        return fractionalISO8601.date(from: trimmed) ?? basicISO8601.date(from: trimmed)
    }

    private static func date(fromEpochNumber value: Double) -> Date {
        if value > 10_000_000_000 {
            return Date(timeIntervalSince1970: value / 1_000)
        }
        return Date(timeIntervalSince1970: value)
    }
}

public enum WhoopPayloadAdapters {
    public static func userID(from json: Any) throws -> String {
        if let dictionary = json as? [String: Any] {
            if let user = dictionary["user"] as? [String: Any], let id = stringValue(user["id"]) {
                return id
            }
            if let id = stringValue(dictionary["id"]) {
                return id
            }
        }
        throw WhoopPayloadError.missingField("user.id")
    }

    public static func sleepActivities(fromCyclesJSON json: Any) -> [WhoopSleepActivity] {
        let records = cycleRecords(from: json)

        var activities: [WhoopSleepActivity] = []
        for record in records {
            guard let dictionary = record as? [String: Any] else { continue }
            for sleepPayload in sleepActivityPayloads(in: dictionary) {
                let sleepDictionary = sleepPayload.dictionary
                let activityID = sleepActivityID(in: sleepDictionary, allowGenericID: sleepPayload.allowsGenericID)
                guard let activityID else { continue }

                activities.append(
                    WhoopSleepActivity(
                        activityID: activityID,
                        sourceUpdatedAt: firstDate(
                            in: sleepDictionary,
                            keys: ["updated_at", "updatedAt", "modified_at", "modifiedAt", "created_at", "createdAt"]
                        ),
                        isNap: boolValue(sleepDictionary["is_nap"])
                            ?? boolValue(sleepDictionary["isNap"])
                            ?? (firstString(in: sleepDictionary, keys: ["sleep_type", "sleepType", "activity_type", "activityType", "type"])?.localizedCaseInsensitiveContains("nap") ?? false)
                    )
                )
            }
        }

        return latestSleepActivities(activities)
    }

    public static func latestSleepActivities(_ activities: [WhoopSleepActivity]) -> [WhoopSleepActivity] {
        var byID: [String: WhoopSleepActivity] = [:]
        for activity in activities {
            if let existing = byID[activity.activityID] {
                let existingUpdatedAt = existing.sourceUpdatedAt ?? .distantPast
                let candidateUpdatedAt = activity.sourceUpdatedAt ?? .distantPast
                if candidateUpdatedAt > existingUpdatedAt {
                    byID[activity.activityID] = activity
                }
            } else {
                byID[activity.activityID] = activity
            }
        }

        return byID.values.sorted { $0.activityID < $1.activityID }
    }

    public static func sleepSession(fromSleepEventsJSON json: Any, activity: WhoopSleepActivity) throws -> SleepSession {
        let root = json as? [String: Any] ?? [:]
        let payload = sleepEventPayload(from: json)
        let payloadRoot = payload.container ?? root
        let rawEvents = payload.events
        guard !rawEvents.isEmpty else {
            throw WhoopPayloadError.missingField("sleep events")
        }

        var parsed: [(stage: SleepStage, start: Date, end: Date?)] = []
        for event in rawEvents {
            guard let dictionary = event as? [String: Any] else { continue }
            let stageRaw = firstString(
                in: dictionary,
                keys: ["type", "stage", "sleep_stage", "sleepStage", "event_type", "eventType"]
            )
            guard let stageRaw, let stage = WhoopStageMapper.map(stageRaw) else {
                continue
            }
            let eventRange = firstTimeRange(
                in: dictionary,
                keys: ["during", "range", "interval", "period", "time_range", "timeRange"]
            )
            guard let start = firstDate(
                in: dictionary,
                keys: ["start_time", "startTime", "started_at", "startedAt", "timestamp", "time", "start"]
            ) ?? eventRange?.start else {
                throw WhoopPayloadError.missingField("sleep event start")
            }
            let end = firstDate(
                in: dictionary,
                keys: ["end_time", "endTime", "ended_at", "endedAt", "end"]
            ) ?? eventRange?.end
            parsed.append((stage, start, end))
        }

        parsed.sort { $0.start < $1.start }
        guard !parsed.isEmpty else {
            throw WhoopPayloadError.noWritableSleepStages
        }

        let rootStart = firstDate(
            in: payloadRoot,
            keys: ["start_time", "startTime", "started_at", "startedAt", "start"]
        ) ?? firstDate(in: root, keys: ["start_time", "startTime", "started_at", "startedAt", "start"])
        let rootEnd = firstDate(
            in: payloadRoot,
            keys: ["end_time", "endTime", "ended_at", "endedAt", "end"]
        ) ?? firstDate(in: root, keys: ["end_time", "endTime", "ended_at", "endedAt", "end"])

        let sessionStart = rootStart ?? parsed.first!.start
        let sessionEnd = rootEnd ?? parsed.compactMap(\.end).max() ?? parsed.last!.start
        guard sessionStart < sessionEnd else {
            throw WhoopPayloadError.invalidDateRange
        }

        var stages: [SleepStageInterval] = []
        for index in parsed.indices {
            let current = parsed[index]
            let derivedEnd = current.end
                ?? parsed.dropFirst(index + 1).first?.start
                ?? rootEnd
            guard let end = derivedEnd, current.start < end else {
                throw WhoopPayloadError.missingField("sleep event end")
            }
            stages.append(SleepStageInterval(start: current.start, end: end, stage: current.stage))
        }

        return try SleepNormalizer.normalize(
            SleepSession(
                whoopSleepID: activity.activityID,
                sourceUpdatedAt: activity.sourceUpdatedAt
                    ?? firstDate(in: payloadRoot, keys: ["updated_at", "updatedAt"])
                    ?? firstDate(in: root, keys: ["updated_at", "updatedAt"]),
                start: sessionStart,
                end: sessionEnd,
                timezoneOffsetSeconds: nil,
                isNap: activity.isNap,
                stages: stages
            )
        )
    }

    public static func heartRatePoints(fromJSON json: Any, stepSeconds: Int) throws -> [HeartRatePoint] {
        let values: [Any]
        if let dictionary = json as? [String: Any] {
            values = heartRateValueEvents(from: dictionary)
        } else if let array = json as? [Any] {
            values = array
        } else {
            throw WhoopPayloadError.unexpectedShape("heart rate root")
        }
        var points: [HeartRatePoint] = []

        for value in values {
            guard let item = value as? [String: Any] else { continue }
            guard let timestamp = firstDate(
                in: item,
                keys: ["time", "timestamp", "start", "start_time", "startTime", "started_at", "startedAt"]
            ) else {
                continue
            }
            guard let bpm = heartRateBPM(from: item) else {
                continue
            }
            guard bpm > 0 else { continue }
            points.append(HeartRatePoint(timestamp: timestamp, bpm: bpm, sourceStepSeconds: stepSeconds))
        }

        return points.sorted { $0.timestamp < $1.timestamp }
    }

    private struct SleepActivityPayload {
        var dictionary: [String: Any]
        var allowsGenericID: Bool
    }

    private static func sleepActivityPayloads(in dictionary: [String: Any]) -> [SleepActivityPayload] {
        var payloads: [SleepActivityPayload] = []
        for key in ["sleeps", "sleepActivities", "sleep_activities"] {
            guard let values = dictionary[key] as? [Any] else { continue }
            for value in values {
                guard let sleepDictionary = value as? [String: Any] else { continue }
                payloads.append(SleepActivityPayload(dictionary: sleepDictionary, allowsGenericID: true))
            }
        }

        for key in ["sleep", "sleepActivity", "sleep_activity"] {
            guard let sleepDictionary = dictionary[key] as? [String: Any] else { continue }
            payloads.append(SleepActivityPayload(dictionary: sleepDictionary, allowsGenericID: true))
        }

        guard payloads.isEmpty else {
            return payloads
        }

        if sleepActivityID(in: dictionary, allowGenericID: false) != nil {
            return [SleepActivityPayload(dictionary: dictionary, allowsGenericID: false)]
        }

        if recordLooksLikeSleepActivity(dictionary),
           sleepActivityID(in: dictionary, allowGenericID: true) != nil {
            return [SleepActivityPayload(dictionary: dictionary, allowsGenericID: true)]
        }

        return []
    }

    private static func sleepActivityID(in dictionary: [String: Any], allowGenericID: Bool) -> String? {
        stringValue(dictionary["activity_id"])
            ?? stringValue(dictionary["activityId"])
            ?? stringValue(dictionary["sleep_id"])
            ?? stringValue(dictionary["sleepId"])
            ?? (allowGenericID ? stringValue(dictionary["id"]) : nil)
    }

    private static func recordLooksLikeSleepActivity(_ dictionary: [String: Any]) -> Bool {
        if boolValue(dictionary["is_sleep"]) == true || boolValue(dictionary["isSleep"]) == true {
            return true
        }
        let type = firstString(
            in: dictionary,
            keys: ["type", "activity_type", "activityType", "kind", "record_type", "recordType"]
        )
        return type?.localizedCaseInsensitiveContains("sleep") ?? false
    }

    private static func cycleRecords(from json: Any, depth: Int = 0) -> [Any] {
        guard depth < 6 else {
            return []
        }
        if let array = json as? [Any] {
            return array
        }
        guard let dictionary = json as? [String: Any] else {
            return []
        }

        for key in ["records", "cycles", "items"] {
            if let records = dictionary[key] as? [Any] {
                return records
            }
        }

        for key in ["data", "payload", "result", "body", "response"] {
            guard let nested = dictionary[key] else { continue }
            let records = cycleRecords(from: nested, depth: depth + 1)
            if !records.isEmpty {
                return records
            }
        }

        return []
    }

    private struct SleepEventPayload {
        var events: [Any]
        var container: [String: Any]?

        static let empty = SleepEventPayload(events: [], container: nil)
    }

    private static func sleepEventPayload(from json: Any, depth: Int = 0) -> SleepEventPayload {
        guard depth < 6 else {
            return .empty
        }
        if let array = json as? [Any] {
            return SleepEventPayload(events: array, container: nil)
        }
        guard let dictionary = json as? [String: Any] else {
            return .empty
        }
        for key in [
            "events",
            "sleep_events",
            "sleepEvents",
            "hypnogram",
            "items",
            "stages",
            "sleep_stages",
            "sleepStages",
            "segments",
            "intervals"
        ] {
            if let array = dictionary[key] as? [Any] {
                return SleepEventPayload(events: array, container: dictionary)
            }
        }

        for key in ["data", "payload", "sleep", "sleepEvent", "sleep_event", "record", "result", "body", "response"] {
            guard let nested = dictionary[key] else { continue }
            let payload = sleepEventPayload(from: nested, depth: depth + 1)
            if !payload.events.isEmpty {
                return payload.container == nil && nested is [Any]
                    ? SleepEventPayload(events: payload.events, container: dictionary)
                    : payload
            }
        }

        return .empty
    }

    private static func heartRateValueEvents(from dictionary: [String: Any]) -> [Any] {
        for key in ["values", "data", "heart_rate", "heartRate"] {
            if let values = dictionary[key] as? [Any] {
                return values
            }
        }

        if let data = dictionary["data"] as? [String: Any] {
            let values = heartRateValueEvents(from: data)
            if !values.isEmpty {
                return values
            }
        }

        if let metrics = dictionary["metrics"] as? [Any] {
            for metric in metrics {
                guard let metricDictionary = metric as? [String: Any] else { continue }
                let name = firstString(in: metricDictionary, keys: ["name", "metric", "type"])
                guard name == nil || name?.lowercased() == "heart_rate" || name?.lowercased() == "heartrate" else {
                    continue
                }
                let values = heartRateValueEvents(from: metricDictionary)
                if !values.isEmpty {
                    return values
                }
            }
        }

        if let metrics = dictionary["metrics"] as? [String: Any] {
            if let heartRate = metrics["heart_rate"] as? [Any] ?? metrics["heartRate"] as? [Any] {
                return heartRate
            }
            if let heartRate = metrics["heart_rate"] as? [String: Any] ?? metrics["heartRate"] as? [String: Any] {
                let values = heartRateValueEvents(from: heartRate)
                if !values.isEmpty {
                    return values
                }
            }
        }

        return []
    }

    private static func heartRateBPM(from item: [String: Any]) -> Double? {
        if let direct = doubleValue(item["data"])
            ?? doubleValue(item["value"])
            ?? doubleValue(item["bpm"])
            ?? doubleValue(item["heart_rate"])
            ?? doubleValue(item["heartRate"]) {
            return direct
        }

        for key in ["data", "value", "values"] {
            guard let nested = item[key] as? [String: Any] else { continue }
            if let nestedValue = doubleValue(nested["heart_rate"])
                ?? doubleValue(nested["heartRate"])
                ?? doubleValue(nested["bpm"])
                ?? doubleValue(nested["value"]) {
                return nestedValue
            }
        }

        return nil
    }

    private static func firstString(in dictionary: [String: Any], keys: [String]) -> String? {
        for key in keys {
            if let value = stringValue(dictionary[key]) {
                return value
            }
        }
        return nil
    }

    private static func firstDate(in dictionary: [String: Any], keys: [String]) -> Date? {
        for key in keys {
            if let date = WhoopDateCodec.date(from: dictionary[key]) {
                return date
            }
        }
        return nil
    }

    private static func firstTimeRange(in dictionary: [String: Any], keys: [String]) -> TimeRange? {
        for key in keys {
            if let range = timeRange(from: dictionary[key]) {
                return range
            }
        }
        return nil
    }

    public static func timeRange(from value: Any?) -> TimeRange? {
        if let dictionary = value as? [String: Any] {
            let start = firstDate(
                in: dictionary,
                keys: ["start_time", "startTime", "started_at", "startedAt", "start", "lower"]
            )
            let end = firstDate(
                in: dictionary,
                keys: ["end_time", "endTime", "ended_at", "endedAt", "end", "upper"]
            )
            guard let start, let end, start < end else {
                return nil
            }
            return TimeRange(start: start, end: end)
        }

        guard let string = value as? String else {
            return nil
        }
        return timeRange(fromPostgresRangeString: string)
    }

    private static func timeRange(fromPostgresRangeString rawValue: String) -> TimeRange? {
        let trimmed = rawValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.count >= 5, trimmed.lowercased() != "empty" else {
            return nil
        }

        var body = trimmed
        if let first = body.first, ["[", "("].contains(first) {
            body.removeFirst()
        }
        if let last = body.last, ["]", ")"].contains(last) {
            body.removeLast()
        }

        let parts = body.split(separator: ",", maxSplits: 1, omittingEmptySubsequences: false)
        guard parts.count == 2 else {
            return nil
        }

        let startString = normalizeRangeBoundary(String(parts[0]))
        let endString = normalizeRangeBoundary(String(parts[1]))
        guard
            let start = WhoopDateCodec.date(from: startString),
            let end = WhoopDateCodec.date(from: endString),
            start < end
        else {
            return nil
        }
        return TimeRange(start: start, end: end)
    }

    private static func normalizeRangeBoundary(_ rawValue: String) -> String {
        rawValue.trimmingCharacters(in: CharacterSet.whitespacesAndNewlines.union(CharacterSet(charactersIn: "'\"")))
    }

    private static func stringValue(_ value: Any?) -> String? {
        switch value {
        case let value as String:
            return value
        case let value as Int:
            return String(value)
        case let value as Int64:
            return String(value)
        case let value as Double where value.rounded() == value:
            return Int64(exactly: value).map { String($0) }
        default:
            return nil
        }
    }

    private static func boolValue(_ value: Any?) -> Bool? {
        switch value {
        case let value as Bool:
            return value
        case let value as String:
            return ["true", "1", "yes"].contains(value.lowercased())
        case let value as Int:
            return value != 0
        default:
            return nil
        }
    }

    private static func doubleValue(_ value: Any?) -> Double? {
        switch value {
        case let value as Double:
            return value
        case let value as Int:
            return Double(value)
        case let value as Int64:
            return Double(value)
        case let value as String:
            return Double(value)
        default:
            return nil
        }
    }
}

public enum WhoopPayloadError: Error, Equatable, LocalizedError {
    case missingField(String)
    case unexpectedShape(String)
    case invalidDateRange
    case noWritableSleepStages

    public var errorDescription: String? {
        switch self {
        case let .missingField(field):
            return "WHOOP payload is missing \(field)."
        case let .unexpectedShape(name):
            return "WHOOP payload has unexpected shape for \(name)."
        case .invalidDateRange:
            return "WHOOP payload contains an invalid date range."
        case .noWritableSleepStages:
            return "WHOOP payload contains no writable sleep stages."
        }
    }
}
