import Foundation
import HealthKit

/// Only write authorization and mutations are exposed. No HealthKit query or read permission.
protocol HealthKitWriting {
    var available: Bool { get }
    func status(for kind: HealthExportKind) -> HKAuthorizationStatus
    func requestAuthorization() async throws
    func save(_ sample: HealthExportSample, version: Int) async throws
    func delete(identifier: String, kind: HealthExportKind) async throws
}

struct HealthKitWriter: HealthKitWriting {
    private let store = HKHealthStore()
    var available: Bool { HKHealthStore.isHealthDataAvailable() }

    private func type(_ kind: HealthExportKind) -> HKSampleType {
        switch kind {
        case .steps: HKQuantityType(.stepCount)
        case .heartRate: HKQuantityType(.heartRate)
        case .sleep: HKCategoryType(.sleepAnalysis)
        }
    }

    func status(for kind: HealthExportKind) -> HKAuthorizationStatus {
        store.authorizationStatus(for: type(kind))
    }

    func requestAuthorization() async throws {
        try await store.requestAuthorization(toShare: Set(HealthExportKind.allCases.map(type)), read: [])
    }

    enum WriterError: Error { case invalidSample }

    func save(_ sample: HealthExportSample, version: Int) async throws {
        guard version > 0, sample.start <= sample.end else { throw WriterError.invalidSample }
        let metadata: [String: Any] = [HKMetadataKeySyncIdentifier: sample.identifier,
                                       HKMetadataKeySyncVersion: version]
        let object: HKSample
        switch sample.kind {
        case .steps:
            guard sample.value > 0, sample.start < sample.end else { throw WriterError.invalidSample }
            object = HKQuantitySample(type: HKQuantityType(.stepCount), quantity: HKQuantity(unit: .count(), doubleValue: Double(sample.value)),
                                      start: sample.start, end: sample.end, metadata: metadata)
        case .heartRate:
            guard ValidRange.heartRate.contains(sample.value) else { throw WriterError.invalidSample }
            let unit = HKUnit.count().unitDivided(by: .minute())
            object = HKQuantitySample(type: HKQuantityType(.heartRate), quantity: HKQuantity(unit: unit, doubleValue: Double(sample.value)),
                                      start: sample.start, end: sample.end, metadata: metadata)
        case .sleep:
            guard sample.start < sample.end, let rawStage = UInt8(exactly: sample.value),
                  let stage = StageKind(rawValue: rawStage) else { throw WriterError.invalidSample }
            let value: HKCategoryValueSleepAnalysis
            switch stage {
            case .awake: value = .awake
            case .light: value = .asleepCore
            case .deep: value = .asleepDeep
            case .rem: value = .asleepREM
            case .unknown, .notSleep: throw WriterError.invalidSample
            }
            object = HKCategorySample(type: HKCategoryType(.sleepAnalysis), value: value.rawValue,
                                      start: sample.start, end: sample.end, metadata: metadata)
        }
        try await store.save(object)
    }

    func delete(identifier: String, kind: HealthExportKind) async throws {
        guard identifier.hasPrefix("freeband.v1.") else { throw WriterError.invalidSample }
        let predicate = HKQuery.predicateForObjects(withMetadataKey: HKMetadataKeySyncIdentifier, allowedValues: [identifier])
        _ = try await store.deleteObjects(of: type(kind), predicate: predicate)
    }
}
