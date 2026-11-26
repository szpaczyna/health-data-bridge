import Foundation

public enum SleepNormalizationError: Error, Equatable, CustomStringConvertible {
    case invalidSessionBounds
    case noWritableStages

    public var description: String {
        switch self {
        case .invalidSessionBounds:
            return "Sleep session start must be before end."
        case .noWritableStages:
            return "Sleep session has no writable REM, core, deep, or awake stages."
        }
    }
}

public enum WhoopStageMapper {
    public static func map(_ rawValue: String) -> SleepStage? {
        let normalized = rawValue
            .uppercased()
            .replacingOccurrences(of: #"[^A-Z0-9]+"#, with: "_", options: .regularExpression)
            .trimmingCharacters(in: CharacterSet(charactersIn: "_"))

        switch normalized {
        case "WAKE", "AWAKE", "WAKEFUL":
            return .awake
        case "LIGHT", "LIGHT_SLEEP", "CORE", "CORE_SLEEP", "ASLEEP_CORE":
            return .core
        case "SWS", "SWS_SLEEP", "DEEP", "DEEP_SLEEP", "SLOW_WAVE", "SLOW_WAVE_SLEEP", "ASLEEP_DEEP":
            return .deep
        case "REM", "REM_SLEEP", "ASLEEP_REM":
            return .rem
        default:
            return nil
        }
    }
}

public enum SleepNormalizer {
    public static func normalize(_ session: SleepSession) throws -> SleepSession {
        guard session.start < session.end else {
            throw SleepNormalizationError.invalidSessionBounds
        }

        let sorted = session.stages.sorted {
            if $0.range.start == $1.range.start {
                return $0.range.end < $1.range.end
            }
            return $0.range.start < $1.range.start
        }

        var normalized: [SleepStageInterval] = []
        for stage in sorted {
            // Throwing on a millisecond overrun or overlap would block the sleep checkpoint permanently.
            let lowerBound = max(session.start, normalized.last?.range.end ?? session.start)
            var clamped = stage
            clamped.range = TimeRange(start: max(stage.range.start, lowerBound), end: min(stage.range.end, session.end))
            guard clamped.range.hasPositiveDuration else {
                continue
            }

            if let last = normalized.last,
               clamped.stage == last.stage && clamped.range.start == last.range.end {
                normalized[normalized.count - 1].range.end = clamped.range.end
                continue
            }
            normalized.append(clamped)
        }

        guard !normalized.isEmpty else {
            throw SleepNormalizationError.noWritableStages
        }

        var output = session
        output.stages = normalized
        return output
    }
}

public enum SleepFingerprint {
    public static func make(for session: SleepSession) -> String {
        var lines: [String] = [
            Self.encode(session.start),
            Self.encode(session.end),
            session.isNap ? "nap" : "main"
        ]
        for stage in session.stages {
            lines.append("\(Self.encode(stage.range.start))|\(Self.encode(stage.range.end))|\(stage.stage.rawValue)")
        }
        return FNV1a64.hash(lines.joined(separator: "\n"))
    }

    private static func encode(_ date: Date) -> String {
        String(format: "%.3f", date.timeIntervalSince1970)
    }
}

private enum FNV1a64 {
    static func hash(_ string: String) -> String {
        var hash: UInt64 = 0xcbf29ce484222325
        let prime: UInt64 = 0x100000001b3
        for byte in string.utf8 {
            hash ^= UInt64(byte)
            hash &*= prime
        }
        return String(format: "%016llx", hash)
    }
}
