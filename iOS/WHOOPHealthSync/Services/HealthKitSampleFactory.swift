import Foundation
import HealthKit
import WHOOPHealthSyncCore

enum HealthKitSampleFactory {
    static let sleepType = HKObjectType.categoryType(forIdentifier: .sleepAnalysis)!
    static let heartRateType = HKObjectType.quantityType(forIdentifier: .heartRate)!
    static let heartRateUnit = HKUnit.count().unitDivided(by: .minute())

    static func sleepSample(from fragment: SleepWriteFragment) -> HKCategorySample {
        HKCategorySample(
            type: sleepType,
            value: healthKitSleepValue(from: fragment.interval.stage),
            start: fragment.interval.range.start,
            end: fragment.interval.range.end,
            metadata: sleepMetadata(for: fragment)
        )
    }

    static func heartRateSample(from point: HeartRatePoint, stepSeconds: Int) -> HKQuantitySample {
        HKQuantitySample(
            type: heartRateType,
            quantity: HKQuantity(unit: heartRateUnit, doubleValue: point.bpm),
            start: point.timestamp,
            end: point.timestamp.addingTimeInterval(TimeInterval(stepSeconds)),
            metadata: heartRateMetadata(for: point, stepSeconds: stepSeconds)
        )
    }

    static func sleepMetadata(for fragment: SleepWriteFragment) -> [String: Any] {
        [
            HKMetadataKeySyncIdentifier: SyncIdentifiers.sleep(
                whoopSleepID: fragment.whoopSleepID,
                stage: fragment.interval.stage,
                start: fragment.interval.range.start,
                end: fragment.interval.range.end
            ),
            HKMetadataKeySyncVersion: MetadataKeys.syncVersion,
            MetadataKeys.whoopSleepID: fragment.whoopSleepID,
            MetadataKeys.whoopSleepFingerprint: fragment.fingerprint,
            MetadataKeys.adapterVersion: MetadataKeys.appVersion
        ]
    }

    static func heartRateMetadata(for point: HeartRatePoint, stepSeconds: Int) -> [String: Any] {
        [
            HKMetadataKeySyncIdentifier: SyncIdentifiers.heartRate(timestamp: point.timestamp, stepSeconds: stepSeconds),
            HKMetadataKeySyncVersion: MetadataKeys.syncVersion,
            MetadataKeys.whoopHeartRateTimestamp: WhoopAPIClient.isoString(point.timestamp),
            MetadataKeys.sourceStepSeconds: stepSeconds,
            MetadataKeys.adapterVersion: MetadataKeys.appVersion
        ]
    }

    static func healthKitSleepValue(from stage: SleepStage) -> Int {
        switch stage {
        case .awake:
            return HKCategoryValueSleepAnalysis.awake.rawValue
        case .core:
            return HKCategoryValueSleepAnalysis.asleepCore.rawValue
        case .deep:
            return HKCategoryValueSleepAnalysis.asleepDeep.rawValue
        case .rem:
            return HKCategoryValueSleepAnalysis.asleepREM.rawValue
        }
    }

    static func existingSleepValue(from rawValue: Int) -> ExistingSleepValue {
        switch rawValue {
        case HKCategoryValueSleepAnalysis.awake.rawValue:
            return .awake
        case HKCategoryValueSleepAnalysis.asleepCore.rawValue:
            return .asleepCore
        case HKCategoryValueSleepAnalysis.asleepDeep.rawValue:
            return .asleepDeep
        case HKCategoryValueSleepAnalysis.asleepREM.rawValue:
            return .asleepREM
        case HKCategoryValueSleepAnalysis.asleepUnspecified.rawValue:
            return .asleepUnspecified
        case HKCategoryValueSleepAnalysis.inBed.rawValue:
            return .inBed
        default:
            return .other(rawValue)
        }
    }
}
