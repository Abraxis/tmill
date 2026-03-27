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
        HKQuantityType(.heartRate),
    ]

    private init() {
        self.syncEnabled = UserDefaults.standard.bool(forKey: "healthKitSyncEnabled")
        self.isAvailable = HKHealthStore.isHealthDataAvailable()
    }

    func requestAuthorization() async -> Bool {
        do {
            try await healthStore.requestAuthorization(toShare: writeTypes, read: readTypes)
            await MainActor.run {
                isAuthorized = true
            }
            logger.info("Authorization granted")
            return true
        } catch {
            logger.error("Authorization failed: \(error.localizedDescription)")
            await MainActor.run {
                isAuthorized = false
            }
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

    /// Fetch heart rate samples from HealthKit for a given time window
    func fetchHeartRateSamples(from startDate: Date, to endDate: Date) async -> [(date: Date, bpm: Int)] {
        logger.info("Fetching HR: available=\(self.isAvailable), authorized=\(self.isAuthorized), from=\(startDate) to=\(endDate)")
        guard isAvailable else {
            logger.warning("HealthKit not available on this device")
            return []
        }

        if !isAuthorized {
            let ok = await requestAuthorization()
            guard ok else {
                logger.warning("HealthKit authorization denied")
                return []
            }
        }

        let heartRateType = HKQuantityType(.heartRate)
        let predicate = HKQuery.predicateForSamples(withStart: startDate, end: endDate, options: .strictStartDate)
        let sortDescriptor = NSSortDescriptor(key: HKSampleSortIdentifierStartDate, ascending: true)

        return await withCheckedContinuation { continuation in
            let query = HKSampleQuery(
                sampleType: heartRateType,
                predicate: predicate,
                limit: HKObjectQueryNoLimit,
                sortDescriptors: [sortDescriptor]
            ) { [weak self] _, samples, error in
                if let error {
                    self?.logger.error("HR query error: \(error.localizedDescription)")
                    continuation.resume(returning: [])
                    return
                }
                guard let samples = samples as? [HKQuantitySample] else {
                    self?.logger.warning("HR query returned nil samples")
                    continuation.resume(returning: [])
                    return
                }
                self?.logger.info("HR query returned \(samples.count) samples")
                let bpmUnit = HKUnit.count().unitDivided(by: .minute())
                let result = samples.map { sample in
                    (date: sample.startDate, bpm: Int(sample.quantity.doubleValue(for: bpmUnit).rounded()))
                }
                continuation.resume(returning: result)
            }
            healthStore.execute(query)
        }
    }
}
