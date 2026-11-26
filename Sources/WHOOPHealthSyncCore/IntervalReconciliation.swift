import Foundation

public enum IntervalAlgebra {
    public static func union(_ ranges: [TimeRange]) -> [TimeRange] {
        let sorted = ranges
            .filter(\.hasPositiveDuration)
            .sorted {
                if $0.start == $1.start {
                    return $0.end < $1.end
                }
                return $0.start < $1.start
            }

        var output: [TimeRange] = []
        for range in sorted {
            guard var last = output.last else {
                output.append(range)
                continue
            }
            if range.start <= last.end {
                last.end = max(last.end, range.end)
                output[output.count - 1] = last
            } else {
                output.append(range)
            }
        }
        return output
    }

    public static func subtract(_ range: TimeRange, coveredBy coverage: [TimeRange]) -> [TimeRange] {
        guard range.hasPositiveDuration else { return [] }

        let coverage = union(coverage)
        var fragments: [TimeRange] = []
        var cursor = range.start

        for covered in coverage {
            guard covered.end > cursor else { continue }
            guard covered.start < range.end else { break }

            if covered.start > cursor {
                fragments.append(TimeRange(start: cursor, end: min(covered.start, range.end)))
            }
            cursor = max(cursor, covered.end)
            if cursor >= range.end {
                break
            }
        }

        if cursor < range.end {
            fragments.append(TimeRange(start: cursor, end: range.end))
        }

        return fragments
    }

    public static func intersections(of range: TimeRange, with coverage: [TimeRange]) -> [TimeRange] {
        union(coverage).compactMap { range.intersection(with: $0) }
    }
}

public enum ExistingSleepValue: Equatable, Sendable {
    case awake
    case asleepCore
    case asleepDeep
    case asleepREM
    case asleep
    case asleepUnspecified
    case inBed
    case other(Int)

    public var isDetailedStage: Bool {
        switch self {
        case .awake, .asleepCore, .asleepDeep, .asleepREM:
            return true
        case .asleep, .asleepUnspecified, .inBed, .other:
            return false
        }
    }
}

public struct ExistingSleepSample: Equatable, Sendable {
    public var id: String
    public var range: TimeRange
    public var value: ExistingSleepValue
    public var isOwnedByApp: Bool
    public var whoopSleepID: String?
    public var whoopSleepFingerprint: String?
    public var syncIdentifier: String?

    public init(
        id: String,
        range: TimeRange,
        value: ExistingSleepValue,
        isOwnedByApp: Bool,
        whoopSleepID: String?,
        whoopSleepFingerprint: String? = nil,
        syncIdentifier: String?
    ) {
        self.id = id
        self.range = range
        self.value = value
        self.isOwnedByApp = isOwnedByApp
        self.whoopSleepID = whoopSleepID
        self.whoopSleepFingerprint = whoopSleepFingerprint
        self.syncIdentifier = syncIdentifier
    }
}

public struct SleepWriteFragment: Equatable, Sendable {
    public var whoopSleepID: String
    public var fingerprint: String
    public var interval: SleepStageInterval

    public init(whoopSleepID: String, fingerprint: String, interval: SleepStageInterval) {
        self.whoopSleepID = whoopSleepID
        self.fingerprint = fingerprint
        self.interval = interval
    }
}

public struct SleepReconciliationPlan: Equatable, Sendable {
    public var fragmentsToWrite: [SleepWriteFragment]
    public var ownSamplesToDelete: [ExistingSleepSample]
    public var skippedDetailedFragments: Int

    public init(
        fragmentsToWrite: [SleepWriteFragment],
        ownSamplesToDelete: [ExistingSleepSample],
        skippedDetailedFragments: Int
    ) {
        self.fragmentsToWrite = fragmentsToWrite
        self.ownSamplesToDelete = ownSamplesToDelete
        self.skippedDetailedFragments = skippedDetailedFragments
    }
}

public enum SleepCoverageReconciler {
    private static let deepDiveSleepIDPrefix = "deep-dive-sleep:"

    public static func plan(
        session: SleepSession,
        existingSamples: [ExistingSleepSample],
        fingerprintChanged: Bool
    ) -> SleepReconciliationPlan {
        let fingerprint = SleepFingerprint.make(for: session)
        let sessionRange = TimeRange(start: session.start, end: session.end)
        let externalDetailed = existingSamples.filter { !$0.isOwnedByApp && $0.value.isDetailedStage }
        let externalCoverage = IntervalAlgebra.union(externalDetailed.map(\.range))

        let ownSamplesToDelete = existingSamples.filter { sample in
            guard sample.isOwnedByApp else { return false }
            let belongsToThisSleep = sample.whoopSleepID == session.whoopSleepID
            let staleByRepository = fingerprintChanged && belongsToThisSleep
            let staleByHealthKitMetadata = belongsToThisSleep
                && sample.whoopSleepFingerprint != nil
                && sample.whoopSleepFingerprint != fingerprint
            let staleFallbackIDMigration = sample.value.isDetailedStage
                && sample.range.overlaps(sessionRange)
                && sample.whoopSleepFingerprint != nil
                && sample.whoopSleepFingerprint != fingerprint
                && isFallbackIDMigration(existingWhoopSleepID: sample.whoopSleepID, incomingWhoopSleepID: session.whoopSleepID)
            let coveredByHigherPrioritySource = sample.value.isDetailedStage && externalCoverage.contains { $0.overlaps(sample.range) }
            return staleByRepository || staleByHealthKitMetadata || staleFallbackIDMigration || coveredByHigherPrioritySource
        }

        let deleteIDs = Set(ownSamplesToDelete.map(\.id))
        let retainedOwnDetailed = existingSamples.filter {
            $0.isOwnedByApp && $0.value.isDetailedStage && !deleteIDs.contains($0.id)
        }
        let totalCoverage = IntervalAlgebra.union(externalCoverage + retainedOwnDetailed.map(\.range))

        var fragments: [SleepWriteFragment] = []
        var skipped = 0
        for stage in session.stages {
            let uncovered = IntervalAlgebra.subtract(stage.range, coveredBy: totalCoverage)
            let coveredFragments = IntervalAlgebra.intersections(of: stage.range, with: totalCoverage)
            skipped += coveredFragments.count

            for range in uncovered {
                fragments.append(
                    SleepWriteFragment(
                        whoopSleepID: session.whoopSleepID,
                        fingerprint: fingerprint,
                        interval: SleepStageInterval(range: range, stage: stage.stage)
                    )
                )
            }
        }

        return SleepReconciliationPlan(
            fragmentsToWrite: fragments,
            ownSamplesToDelete: ownSamplesToDelete,
            skippedDetailedFragments: skipped
        )
    }

    private static func isFallbackIDMigration(existingWhoopSleepID: String?, incomingWhoopSleepID: String) -> Bool {
        guard let existingWhoopSleepID else {
            return false
        }
        return existingWhoopSleepID.hasPrefix(deepDiveSleepIDPrefix) != incomingWhoopSleepID.hasPrefix(deepDiveSleepIDPrefix)
    }
}
