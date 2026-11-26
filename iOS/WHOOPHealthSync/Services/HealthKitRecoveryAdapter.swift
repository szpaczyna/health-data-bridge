import Foundation
import HealthKit
import WHOOPHealthSyncCore

/// SDK 27 symbols deliberately remain isolated. Enable WHOOP_IOS27_SDK only with an actual SDK 27.
@MainActor
final class HealthKitRecoveryAdapter: RecoveryHealthProviding {
    private let store: HKHealthStore
    private let manualConfirmation: () -> Bool
    private let officialBundle: () -> String?
    private let appBundle: String
    init(store: HKHealthStore = HKHealthStore(), appBundle: String = Bundle.main.bundleIdentifier ?? "com.joselourido.WHOOPHealthSync", manualConfirmation: @escaping () -> Bool = { false }, officialBundle: @escaping () -> String? = { nil }) {
        self.manualConfirmation = manualConfirmation; self.officialBundle = officialBundle
        self.store = store; self.appBundle = appBundle
    }
    var supported: Bool {
        #if WHOOP_IOS27_SDK && os(iOS)
        if #available(iOS 27, *) { return HKObjectType.quantityType(forIdentifier: .heartRateVariabilityRMSSD) != nil }
        #endif
        return false
    }
    #if WHOOP_IOS27_SDK && os(iOS)
    @available(iOS 27, *)
    private var type: HKQuantityType? { HKObjectType.quantityType(forIdentifier: .heartRateVariabilityRMSSD) }
    #endif
    func requestAuthorization() async throws {
        #if WHOOP_IOS27_SDK && os(iOS)
        if #available(iOS 27, *) {
            guard let type else { throw RecoverySyncError.unavailable }
            guard HKHealthStore.isHealthDataAvailable() else { throw HealthKitSyncError.healthDataUnavailable }
            try await store.requestAuthorization(toShare: [type], read: [type])
            try validateWriteAuthorization()
            return
        }
        #endif
        throw RecoverySyncError.unavailable
    }
    func validateWriteAuthorization() throws {
        #if WHOOP_IOS27_SDK && os(iOS)
        if #available(iOS 27, *), let type {
            guard store.authorizationStatus(for: type) == .sharingAuthorized else {
                throw HealthKitSyncError.writeAuthorizationDenied(["Recovery HRV"])
            }
            return
        }
        #endif
        throw RecoverySyncError.unavailable
    }
    func readAccess() async throws -> HealthReadAccess {
        #if WHOOP_IOS27_SDK && os(iOS)
        if #available(iOS 27, *) {
            guard let type else { return .unknown }
            let visibleSources = try await sources(for: type)
            if let native = visibleSources.first(where: { $0.bundleIdentifier != appBundle && $0.bundleIdentifier == officialBundle() }) {
                return .nativeExporter(bundle: native.bundleIdentifier)
            }
            let dates: [HKObjectType: Date] = try await withCheckedThrowingContinuation { continuation in
                store.getEarliestAuthorizedSampleDate(for: [type]) { dates, error in
                    if let error { continuation.resume(throwing: error) }
                    else { continuation.resume(returning: dates ?? [:]) }
                }
            }
            if let date = dates[type] { return .limited(since: date) }
            // Empty/own-only is ambiguous. An observed external sample is evidence, never a stored permission.
            let external = NSCompoundPredicate(notPredicateWithSubpredicate: HKQuery.predicateForObjects(from: HKSource.default()))
            let samples = try await query(predicate: external, limit: 1)
            if samples.contains(where: { $0.sourceRevision.source.bundleIdentifier != appBundle }) { return .externallyVisible }
            return manualConfirmation() ? .userConfirmedFullAccess : .unknown
        }
        #endif
        return .unknown
    }
    func observedWhoopSources() async throws -> [RecoveryHealthSource] {
        let heart = HKQuantityType.quantityType(forIdentifier: .heartRate)!
        var list = try await sources(for: heart)
        #if WHOOP_IOS27_SDK && os(iOS)
        if #available(iOS 27, *), let type {
            for source in try await sources(for: type) where !list.contains(where: { $0.bundleIdentifier == source.bundleIdentifier }) { list.append(source) }
        }
        #endif
        return list.filter { $0.bundleIdentifier != appBundle }.map { RecoveryHealthSource(name: $0.name, bundle: $0.bundleIdentifier) }
            .sorted { $0.name < $1.name }
    }
    private func sources(for type: HKSampleType) async throws -> [HKSource] {
        try await withCheckedThrowingContinuation { continuation in
            let query = HKSourceQuery(sampleType: type, samplePredicate: nil) { _, sources, error in
                if let error { continuation.resume(throwing: error) }
                else { continuation.resume(returning: Array(sources ?? [])) }
            }
            store.execute(query)
        }
    }
    func samples(in window: TimeRange, identifier: String) async throws -> [ExistingRecoverySample] {
        #if WHOOP_IOS27_SDK && os(iOS)
        if #available(iOS 27, *) {
            guard type != nil else { throw RecoverySyncError.unavailable }
            let period = HKQuery.predicateForSamples(withStart: window.start, end: window.end, options: [])
            let identity = HKQuery.predicateForObjects(withMetadataKey: HKMetadataKeySyncIdentifier, allowedValues: [identifier])
            let samples = try await query(predicate: NSCompoundPredicate(orPredicateWithSubpredicates: [period, identity]))
            return samples.map {
                ExistingRecoverySample(range: TimeRange(start: $0.startDate, end: $0.endDate),
                    sourceBundle: $0.sourceRevision.source.bundleIdentifier, identifier: $0.metadata?[HKMetadataKeySyncIdentifier] as? String,
                    fingerprint: $0.metadata?[MetadataKeys.recoveryFingerprint] as? String,
                    version: ($0.metadata?[HKMetadataKeySyncVersion] as? NSNumber)?.intValue ?? 0,
                    recognizedMetadata: Self.owned($0, appBundle: appBundle))
            }
        }
        #endif
        throw RecoverySyncError.unavailable
    }
    func save(_ recovery: WhoopRecovery, fingerprint: String, version: Int) async throws {
        try Task.checkCancellation()
        #if WHOOP_IOS27_SDK && os(iOS)
        if #available(iOS 27, *) {
            guard let type else { throw RecoverySyncError.unavailable }
            guard store.authorizationStatus(for: type) == .sharingAuthorized else {
                throw HealthKitSyncError.writeAuthorizationDenied(["Recovery HRV"])
            }
            guard try recovery.fingerprint() == fingerprint, version > 0 else { throw RecoverySyncError.invalidRecord }
            let sample = try Self.makeSample(recovery, fingerprint: fingerprint, version: version)
            try await store.save(sample)
            return
        }
        #endif
        throw RecoverySyncError.unavailable
    }
    #if WHOOP_IOS27_SDK && os(iOS)
    @available(iOS 27, *)
    static func makeSample(_ recovery: WhoopRecovery, fingerprint: String, version: Int) throws -> HKQuantitySample {
        guard try recovery.fingerprint() == fingerprint, version > 0,
              let milliseconds = recovery.milliseconds else { throw RecoverySyncError.invalidRecord }
        let metadata: [String: Any] = [
            HKMetadataKeySyncIdentifier: recovery.identifier, HKMetadataKeySyncVersion: version,
            MetadataKeys.recoveryFingerprint: fingerprint, MetadataKeys.recoveryCycleID: recovery.cycleID,
            MetadataKeys.whoopSleepID: recovery.sleepID, MetadataKeys.recoveryMethod: "RMSSD",
            MetadataKeys.recoveryUnit: "ms", MetadataKeys.recoveryTimestampBasis: "sleepEndSummary",
            MetadataKeys.adapterVersion: recovery.adapterVersion
        ]
        guard let quantityType = HKObjectType.quantityType(forIdentifier: .heartRateVariabilityRMSSD) else { throw RecoverySyncError.unavailable }
        return HKQuantitySample(type: quantityType,
            quantity: HKQuantity(unit: .secondUnit(with: .milli), doubleValue: milliseconds),
            start: recovery.representedDate, end: recovery.representedDate, metadata: metadata)
    }
    #endif
    private static func owned(_ sample: HKQuantitySample, appBundle: String) -> Bool {
        sample.sourceRevision.source.bundleIdentifier == appBundle
            && sample.metadata?[MetadataKeys.recoveryMethod] as? String == "RMSSD"
            && (sample.metadata?[HKMetadataKeySyncIdentifier] as? String)?.hasPrefix("whoop-rmssd:") == true
            && sample.metadata?[MetadataKeys.recoveryFingerprint] as? String != nil
    }
    #if WHOOP_IOS27_SDK && os(iOS)
    @available(iOS 27, *)
    private func query(predicate: NSPredicate?, limit: Int = HKObjectQueryNoLimit) async throws -> [HKQuantitySample] {
        guard let type else { throw RecoverySyncError.unavailable }
        return try await withCheckedThrowingContinuation { continuation in
            let query = HKSampleQuery(sampleType: type, predicate: predicate, limit: limit, sortDescriptors: nil) { _, samples, error in
                if let error { continuation.resume(throwing: error) }
                else { continuation.resume(returning: samples as? [HKQuantitySample] ?? []) }
            }
            store.execute(query)
        }
    }
    #endif
}
