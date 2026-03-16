import HealthKit
import Foundation
import os

@Observable
final class HealthKitManager {
    static let shared = HealthKitManager()

    private(set) var isAvailable = false
    private(set) var isAuthorized = false
    var syncEnabled: Bool {
        didSet { UserDefaults.standard.set(syncEnabled, forKey: "healthKitSyncEnabled") }
    }

    private let healthStore = HKHealthStore()
    private let logger = Logger(subsystem: "com.mymill.app", category: "HealthKit")

    private let writeTypes: Set<HKSampleType> = [
        HKObjectType.workoutType(),
        HKQuantityType(.activeEnergyBurned),
        HKQuantityType(.distanceWalkingRunning),
        HKQuantityType(.runningSpeed),
    ]

    private let readTypes: Set<HKObjectType> = [
        HKObjectType.workoutType(),
    ]

    private init() {
        self.syncEnabled = UserDefaults.standard.bool(forKey: "healthKitSyncEnabled")
        // On macOS, isHealthDataAvailable() returns false even though the framework works.
        // We attempt authorization regardless and set isAvailable based on the result.
        self.isAvailable = true
    }

    func requestAuthorization() async -> Bool {
        do {
            try await healthStore.requestAuthorization(toShare: writeTypes, read: readTypes)
            isAuthorized = true
            logger.info("HealthKit authorization granted")
            return true
        } catch {
            logger.error("HealthKit authorization failed: \(error.localizedDescription)")
            isAuthorized = false
            isAvailable = false
            return false
        }
    }

    /// Save a completed treadmill workout to HealthKit
    func saveWorkout(
        startDate: Date,
        endDate: Date,
        distanceMeters: Double,
        calories: Int,
        avgSpeedKmh: Double,
        maxSpeedKmh: Double,
        speedSamples: [(date: Date, speedKmh: Double)]
    ) async {
        guard isAvailable, syncEnabled else { return }

        if !isAuthorized {
            let ok = await requestAuthorization()
            guard ok else { return }
        }

        do {
            let configuration = HKWorkoutConfiguration()
            configuration.activityType = .walking
            configuration.locationType = .indoor

            let builder = HKWorkoutBuilder(
                healthStore: healthStore,
                configuration: configuration,
                device: .local()
            )

            try await builder.beginCollection(at: startDate)

            var samples: [HKSample] = []

            // Distance (cumulative)
            let distanceSample = HKCumulativeQuantitySample(
                type: HKQuantityType(.distanceWalkingRunning),
                quantity: HKQuantity(unit: .meter(), doubleValue: distanceMeters),
                start: startDate,
                end: endDate
            )
            samples.append(distanceSample)

            // Calories (cumulative)
            if calories > 0 {
                let calSample = HKCumulativeQuantitySample(
                    type: HKQuantityType(.activeEnergyBurned),
                    quantity: HKQuantity(unit: .kilocalorie(), doubleValue: Double(calories)),
                    start: startDate,
                    end: endDate
                )
                samples.append(calSample)
            }

            // Speed samples (discrete)
            let speedUnit = HKUnit.meter().unitDivided(by: .second())
            for s in speedSamples where s.speedKmh > 0 {
                let speedMs = s.speedKmh / 3.6
                let sample = HKQuantitySample(
                    type: HKQuantityType(.runningSpeed),
                    quantity: HKQuantity(unit: speedUnit, doubleValue: speedMs),
                    start: s.date,
                    end: s.date
                )
                samples.append(sample)
            }

            try await builder.addSamples(samples)

            // Metadata
            var metadata: [String: Any] = [
                HKMetadataKeyIndoorWorkout: true,
            ]
            if avgSpeedKmh > 0 {
                metadata[HKMetadataKeyAverageSpeed] = HKQuantity(
                    unit: speedUnit, doubleValue: avgSpeedKmh / 3.6
                )
            }
            if maxSpeedKmh > 0 {
                metadata[HKMetadataKeyMaximumSpeed] = HKQuantity(
                    unit: speedUnit, doubleValue: maxSpeedKmh / 3.6
                )
            }

            try await builder.addMetadata(metadata)
            try await builder.endCollection(at: endDate)
            let workout = try await builder.finishWorkout()

            logger.info("HealthKit workout saved: \(workout?.totalDistance?.description ?? "?")")
        } catch {
            logger.error("HealthKit save failed: \(error.localizedDescription)")
        }
    }
}
