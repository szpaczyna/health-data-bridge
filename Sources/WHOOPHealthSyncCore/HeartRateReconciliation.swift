import Foundation

public enum HeartRateTimestampSemantics: Sendable {
    case bucketStart
    case bucketCenter
}

public struct ExistingHeartRateSample: Equatable, Sendable {
    public var id: String
    public var range: TimeRange
    public var bpm: Double
    public var isOwnedByApp: Bool
    public var syncIdentifier: String?

    public init(
        id: String,
        range: TimeRange,
        bpm: Double,
        isOwnedByApp: Bool,
        syncIdentifier: String?
    ) {
        self.id = id
        self.range = range
        self.bpm = bpm
        self.isOwnedByApp = isOwnedByApp
        self.syncIdentifier = syncIdentifier
    }
}

public struct HeartRateReconciliationPlan: Equatable, Sendable {
    public var pointsToWrite: [HeartRatePoint]
    public var ownSamplesToDelete: [ExistingHeartRateSample]
    public var skippedPointCount: Int
    public var externalDuplicateCount: Int
    public var replacedOwnPointCount: Int

    public init(
        pointsToWrite: [HeartRatePoint],
        ownSamplesToDelete: [ExistingHeartRateSample],
        skippedPointCount: Int,
        externalDuplicateCount: Int,
        replacedOwnPointCount: Int
    ) {
        self.pointsToWrite = pointsToWrite
        self.ownSamplesToDelete = ownSamplesToDelete
        self.skippedPointCount = skippedPointCount
        self.externalDuplicateCount = externalDuplicateCount
        self.replacedOwnPointCount = replacedOwnPointCount
    }
}

public enum HeartRateCoverageReconciler {
    public static func bucket(
        for point: HeartRatePoint,
        stepSeconds: Int,
        semantics: HeartRateTimestampSemantics
    ) -> TimeRange {
        let step = TimeInterval(stepSeconds)
        switch semantics {
        case .bucketStart:
            return TimeRange(start: point.timestamp, end: point.timestamp.addingTimeInterval(step))
        case .bucketCenter:
            return TimeRange(
                start: point.timestamp.addingTimeInterval(-step / 2),
                end: point.timestamp.addingTimeInterval(step / 2)
            )
        }
    }

    public static func plan(
        points: [HeartRatePoint],
        existingSamples: [ExistingHeartRateSample],
        stepSeconds: Int,
        semantics: HeartRateTimestampSemantics = .bucketStart,
        equivalentToleranceBPM: Double = 0.5
    ) -> HeartRateReconciliationPlan {
        let sortedPoints = points.sorted { $0.timestamp < $1.timestamp }
        let sortedExisting = existingSamples.sorted {
            if $0.range.start == $1.range.start {
                return $0.range.end < $1.range.end
            }
            return $0.range.start < $1.range.start
        }

        var cursor = 0
        var overlapsByPoint: [[ExistingHeartRateSample]] = []
        overlapsByPoint.reserveCapacity(sortedPoints.count)
        for point in sortedPoints {
            let bucket = bucket(for: point, stepSeconds: stepSeconds, semantics: semantics)
            while cursor < sortedExisting.count && isStrictlyBeforeBucket(sortedExisting[cursor], bucket: bucket) {
                cursor += 1
            }

            var overlaps: [ExistingHeartRateSample] = []
            var index = cursor
            while index < sortedExisting.count && sortedExisting[index].range.start < bucket.end {
                if overlapsBucket(sortedExisting[index], bucket: bucket) {
                    overlaps.append(sortedExisting[index])
                }
                index += 1
            }
            overlapsByPoint.append(overlaps)
        }

        // Points closer than one step overlap each other's own samples; an equivalent kept for one point must survive the rest.
        var equivalentByPoint: [ExistingHeartRateSample?] = []
        equivalentByPoint.reserveCapacity(sortedPoints.count)
        var keptIDs = Set<String>()
        for (point, overlaps) in zip(sortedPoints, overlapsByPoint) {
            let bucket = bucket(for: point, stepSeconds: stepSeconds, semantics: semantics)
            let equivalent = overlaps.contains { !$0.isOwnedByApp } ? nil : overlaps.first {
                $0.isOwnedByApp && $0.range == bucket && abs($0.bpm - point.bpm) <= equivalentToleranceBPM
            }
            if let equivalent {
                keptIDs.insert(equivalent.id)
            }
            equivalentByPoint.append(equivalent)
        }

        var pointsToWrite: [HeartRatePoint] = []
        var samplesToDelete: [ExistingHeartRateSample] = []
        var skipped = 0
        var externalDuplicates = 0
        var replacedOwn = 0
        var deletedIDs = Set<String>()

        for (pointIndex, point) in sortedPoints.enumerated() {
            let overlaps = overlapsByPoint[pointIndex]
            let external = overlaps.filter { !$0.isOwnedByApp }
            let owned = overlaps.filter(\.isOwnedByApp)

            if !external.isEmpty {
                externalDuplicates += 1
                skipped += 1
                for sample in owned where !deletedIDs.contains(sample.id) && !keptIDs.contains(sample.id) {
                    samplesToDelete.append(sample)
                    deletedIDs.insert(sample.id)
                }
                continue
            }

            if !owned.isEmpty {
                if equivalentByPoint[pointIndex] != nil {
                    skipped += 1
                } else {
                    replacedOwn += 1
                    pointsToWrite.append(point)
                }
                for sample in owned where !deletedIDs.contains(sample.id) && !keptIDs.contains(sample.id) {
                    samplesToDelete.append(sample)
                    deletedIDs.insert(sample.id)
                }
                continue
            }

            pointsToWrite.append(point)
        }

        return HeartRateReconciliationPlan(
            pointsToWrite: pointsToWrite,
            ownSamplesToDelete: samplesToDelete,
            skippedPointCount: skipped,
            externalDuplicateCount: externalDuplicates,
            replacedOwnPointCount: replacedOwn
        )
    }

    private static func isStrictlyBeforeBucket(_ sample: ExistingHeartRateSample, bucket: TimeRange) -> Bool {
        if sample.range.hasPositiveDuration {
            return sample.range.end <= bucket.start
        }
        return sample.range.start < bucket.start
    }

    private static func overlapsBucket(_ sample: ExistingHeartRateSample, bucket: TimeRange) -> Bool {
        if sample.range.hasPositiveDuration {
            return sample.range.overlaps(bucket)
        }
        return sample.range.start >= bucket.start && sample.range.start < bucket.end
    }
}
