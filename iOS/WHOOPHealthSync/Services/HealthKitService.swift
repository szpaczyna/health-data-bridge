import Foundation
import HealthKit
import WHOOPHealthSyncCore

struct RecoveryHealthSource: Identifiable, Equatable {
    var name: String
    var bundle: String
    var id: String { bundle }
}

struct RecoveryAuthorization {
    var sources: [RecoveryHealthSource]
    var access: HealthReadAccess
    var writeAuthorized = true
}

struct SyncDataAuthorization {
    var sleepWriteAuthorized: Bool
    var heartRateWriteAuthorized: Bool
    // nil means unknown, never full-read authorization.
    var sleepReadBoundary: Date?
    var heartRateReadBoundary: Date?
    var recovery: RecoveryAuthorization?
    var baseWriteAuthorized: Bool { sleepWriteAuthorized && heartRateWriteAuthorized }
}

struct HealthKitSleepSampleRecord {
    var sample: HKCategorySample
    var existing: ExistingSleepSample
}

struct HealthKitHeartRateSampleRecord {
    var sample: HKQuantitySample
    var existing: ExistingHeartRateSample
}

final class HealthKitService {
    private let store = HKHealthStore()
    private let sleepType = HealthKitSampleFactory.sleepType
    private let heartRateType = HealthKitSampleFactory.heartRateType
    private let heartRateUnit = HealthKitSampleFactory.heartRateUnit

    func authorizedBoundary(for type: String) async throws -> Date? {
        #if os(iOS)
        if #available(iOS 27, *) {
            #if WHOOP_IOS27_SDK
            let objectType: HKObjectType = type == "sleep" ? sleepType : heartRateType
            let dates: [HKObjectType: Date] = try await withCheckedThrowingContinuation { continuation in
                store.getEarliestAuthorizedSampleDate(for: [objectType]) { dates, error in
                    if let error { continuation.resume(throwing: error) }
                    else { continuation.resume(returning: dates ?? [:]) }
                }
            }
            return dates[objectType]
            #else
            throw RecoverySyncError.unavailable
            #endif
        }
        #endif
        return nil
    }

    func requestAuthorization() async throws {
        try await requestAuthorization(includeRecovery: false)
    }

    func requestAuthorization(includeRecovery: Bool) async throws {
        let result = try await requestSelectedAuthorization(includeRecovery: includeRecovery)
        var denied: [String] = []
        if !result.sleepWriteAuthorized { denied.append("Sleep Analysis") }
        if !result.heartRateWriteAuthorized { denied.append("Heart Rate") }
        if !denied.isEmpty { throw HealthKitSyncError.writeAuthorizationDenied(denied) }
    }

    func requestSelectedAuthorization(includeRecovery: Bool) async throws -> SyncDataAuthorization {
        guard HKHealthStore.isHealthDataAvailable() else {
            throw HealthKitSyncError.healthDataUnavailable
        }

        var shareTypes: Set<HKSampleType> = [sleepType, heartRateType]
        var readTypes: Set<HKObjectType> = [sleepType, heartRateType]
        #if WHOOP_IOS27_SDK && os(iOS)
        if #available(iOS 27, *), includeRecovery,
           let recovery = HKObjectType.quantityType(forIdentifier: .heartRateVariabilityRMSSD) {
            shareTypes.insert(recovery)
            readTypes.insert(recovery)
        }
        #endif

        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            store.requestAuthorization(toShare: shareTypes, read: readTypes) { success, error in
                if let error {
                    continuation.resume(throwing: error)
                    return
                }
                guard success else {
                    continuation.resume(throwing: HealthKitSyncError.authorizationRejected)
                    return
                }
                continuation.resume()
            }
        }
        return SyncDataAuthorization(
            sleepWriteAuthorized: store.authorizationStatus(for: sleepType) == .sharingAuthorized,
            heartRateWriteAuthorized: store.authorizationStatus(for: heartRateType) == .sharingAuthorized,
            sleepReadBoundary: try await authorizedBoundary(for: "sleep"),
            heartRateReadBoundary: try await authorizedBoundary(for: "heartRate"), recovery: nil)
    }

    func validateExistingAuthorization() throws {
        guard HKHealthStore.isHealthDataAvailable() else {
            throw HealthKitSyncError.healthDataUnavailable
        }
        try Self.validateWriteAuthorization(
            sleepStatus: store.authorizationStatus(for: sleepType),
            heartRateStatus: store.authorizationStatus(for: heartRateType)
        )
    }

    func querySleepSamples(from start: Date, to end: Date) async throws -> [HealthKitSleepSampleRecord] {
        let predicate = HKQuery.predicateForSamples(withStart: start, end: end, options: [])
        let samples: [HKCategorySample] = try await runSampleQuery(sampleType: sleepType, predicate: predicate)
        AppLog.healthKit.info("Read \(samples.count) sleep samples from HealthKit.")
        return samples.map { sample in
            HealthKitSleepSampleRecord(
                sample: sample,
                existing: ExistingSleepSample(
                    id: sample.uuid.uuidString,
                    range: TimeRange(start: sample.startDate, end: sample.endDate),
                    value: HealthKitSampleFactory.existingSleepValue(from: sample.value),
                    isOwnedByApp: isOwnedByThisApp(sample),
                    whoopSleepID: sample.metadata?[MetadataKeys.whoopSleepID] as? String,
                    whoopSleepFingerprint: sample.metadata?[MetadataKeys.whoopSleepFingerprint] as? String,
                    syncIdentifier: sample.metadata?[HKMetadataKeySyncIdentifier] as? String
                )
            )
        }
    }

    func saveSleepFragments(_ fragments: [SleepWriteFragment]) async throws {
        guard !fragments.isEmpty else { return }
        let samples = fragments.map { HealthKitSampleFactory.sleepSample(from: $0) }
        try await save(samples)
        AppLog.healthKit.info("Saved \(samples.count) detailed sleep samples to HealthKit.")
    }

    func deleteSleepSamples(_ records: [HealthKitSleepSampleRecord]) async throws {
        guard !records.isEmpty else { return }
        try await delete(records.map(\.sample))
        AppLog.healthKit.info("Deleted \(records.count) app-owned sleep samples from HealthKit.")
    }

    func queryHeartRateSamples(from start: Date, to end: Date) async throws -> [HealthKitHeartRateSampleRecord] {
        let predicate = HKQuery.predicateForSamples(withStart: start, end: end, options: [])
        let samples: [HKQuantitySample] = try await runSampleQuery(sampleType: heartRateType, predicate: predicate)
        AppLog.healthKit.info("Read \(samples.count) heart-rate samples from HealthKit.")
        return samples.map { sample in
            HealthKitHeartRateSampleRecord(
                sample: sample,
                existing: ExistingHeartRateSample(
                    id: sample.uuid.uuidString,
                    range: TimeRange(start: sample.startDate, end: sample.endDate),
                    bpm: sample.quantity.doubleValue(for: heartRateUnit),
                    isOwnedByApp: isOwnedByThisApp(sample),
                    syncIdentifier: sample.metadata?[HKMetadataKeySyncIdentifier] as? String
                )
            )
        }
    }

    func saveHeartRatePoints(_ points: [HeartRatePoint], stepSeconds: Int) async throws {
        guard !points.isEmpty else { return }
        let samples = points.map { HealthKitSampleFactory.heartRateSample(from: $0, stepSeconds: stepSeconds) }
        try await save(samples)
        AppLog.healthKit.info("Saved \(samples.count) heart-rate samples to HealthKit.")
    }

    func deleteHeartRateSamples(_ records: [HealthKitHeartRateSampleRecord]) async throws {
        guard !records.isEmpty else { return }
        try await delete(records.map(\.sample))
        AppLog.healthKit.info("Deleted \(records.count) app-owned heart-rate samples from HealthKit.")
    }

    func hasSleepSamples(from start: Date, to end: Date) async throws -> Bool {
        let predicate = HKQuery.predicateForSamples(withStart: start, end: end, options: [])
        let samples: [HKCategorySample] = try await runSampleQuery(sampleType: sleepType, predicate: predicate, limit: 1)
        return !samples.isEmpty
    }

    func hasHeartRateSamples(from start: Date, to end: Date) async throws -> Bool {
        let predicate = HKQuery.predicateForSamples(withStart: start, end: end, options: [])
        let samples: [HKQuantitySample] = try await runSampleQuery(sampleType: heartRateType, predicate: predicate, limit: 1)
        return !samples.isEmpty
    }

    private func runSampleQuery<T: HKSample>(sampleType: HKSampleType, predicate: NSPredicate, limit: Int = HKObjectQueryNoLimit) async throws -> [T] {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<[T], Error>) in
            let query = HKSampleQuery(
                sampleType: sampleType,
                predicate: predicate,
                limit: limit,
                sortDescriptors: [NSSortDescriptor(key: HKSampleSortIdentifierStartDate, ascending: true)]
            ) { _, samples, error in
                if let error {
                    continuation.resume(throwing: error)
                    return
                }
                continuation.resume(returning: (samples as? [T]) ?? [])
            }
            store.execute(query)
        }
    }

    private func save(_ samples: [HKSample]) async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            store.save(samples) { success, error in
                if let error {
                    continuation.resume(throwing: error)
                    return
                }
                guard success else {
                    continuation.resume(throwing: HealthKitSyncError.saveRejected)
                    return
                }
                continuation.resume()
            }
        }
    }

    private func delete(_ samples: [HKSample]) async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            store.delete(samples) { success, error in
                if let error {
                    continuation.resume(throwing: error)
                    return
                }
                guard success else {
                    continuation.resume(throwing: HealthKitSyncError.deleteRejected)
                    return
                }
                continuation.resume()
            }
        }
    }

    private func isOwnedByThisApp(_ sample: HKSample) -> Bool {
        guard let bundleIdentifier = Bundle.main.bundleIdentifier else {
            return false
        }
        return sample.sourceRevision.source.bundleIdentifier == bundleIdentifier
            && MetadataKeys.isRecognizedAppMetadata(sample.metadata)
    }

    static func validateWriteAuthorization(
        sleepStatus: HKAuthorizationStatus,
        heartRateStatus: HKAuthorizationStatus
    ) throws {
        var deniedTypes: [String] = []
        if sleepStatus != .sharingAuthorized {
            deniedTypes.append("Sleep Analysis")
        }
        if heartRateStatus != .sharingAuthorized {
            deniedTypes.append("Heart Rate")
        }
        guard deniedTypes.isEmpty else {
            throw HealthKitSyncError.writeAuthorizationDenied(deniedTypes)
        }
    }

}

enum HealthKitSyncError: Error, LocalizedError {
    case healthDataUnavailable
    case authorizationRejected
    case writeAuthorizationDenied([String])
    case saveRejected
    case deleteRejected

    var errorDescription: String? {
        switch self {
        case .healthDataUnavailable:
            return "Health data is not available on this device."
        case .authorizationRejected:
            return "HealthKit authorization was not granted."
        case let .writeAuthorizationDenied(types):
            return "HealthKit write authorization missing for \(types.joined(separator: ", "))."
        case .saveRejected:
            return "HealthKit rejected the save operation."
        case .deleteRejected:
            return "HealthKit rejected the delete operation."
        }
    }
}
