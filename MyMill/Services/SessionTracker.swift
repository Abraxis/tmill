// Services/SessionTracker.swift
import CoreData
import Foundation
import os

@Observable
final class SessionTracker {
    private(set) var isRecording = false

    private let state: MyMillState
    private let persistence: PersistenceController
    private let minDuration: TimeInterval

    private var sessionStartDate: Date?
    private var samples: [WorkoutSession.Sample] = []
    private var maxSpeed: Double = 0
    private var inclineSum: Double = 0
    private var inclineSampleCount: Int = 0
    private var sessionStartDistance: Double = 0
    private var sessionStartElapsed: TimeInterval = 0
    private var sessionStartCalories: Int = 0

    private let logger = Logger(subsystem: "com.mymill.app", category: "SessionTracker")

    init(state: MyMillState, persistence: PersistenceController, minDuration: TimeInterval = 300) {
        self.state = state
        self.persistence = persistence
        self.minDuration = minDuration
    }

    /// Call periodically (e.g., every second) or on state changes.
    func check() {
        if state.isRunning && !isRecording {
            startRecording()
        } else if !state.isRunning && isRecording {
            stopRecording()
        }
    }

    func recordSample() {
        guard isRecording else { return }
        let sample = WorkoutSession.Sample(
            time: state.elapsed - sessionStartElapsed,
            speed: state.speed,
            incline: state.incline
        )
        samples.append(sample)
        maxSpeed = max(maxSpeed, state.speed)
        if state.incline > 0 || inclineSampleCount > 0 {
            inclineSum += state.incline
            inclineSampleCount += 1
        }
    }

    // MARK: - Private

    private func startRecording() {
        isRecording = true
        sessionStartDate = Date()
        sessionStartDistance = state.distance
        sessionStartElapsed = state.elapsed
        sessionStartCalories = state.calories
        samples = []
        maxSpeed = 0
        inclineSum = 0
        inclineSampleCount = 0
        logger.info("Session recording started")
    }

    private func stopRecording() {
        isRecording = false

        // Trim trailing zero-speed samples from hysteresis
        samples = WorkoutSession.trimTrailingZeros(from: samples)

        let duration = state.elapsed - sessionStartElapsed
        logger.info("Session recording stopped, duration: \(duration)s")

        guard duration >= minDuration else {
            logger.info("Session too short (\(duration)s < \(self.minDuration)s), discarding")
            return
        }

        saveSession(duration: duration)
    }

    private func buildStravaSamples() -> [(timeOffset: TimeInterval, speed: Double, distance: Double, altitude: Double)] {
        Self.buildStravaSamples(from: samples)
    }

    static func buildStravaSamples(from samples: [WorkoutSession.Sample]) -> [(timeOffset: TimeInterval, speed: Double, distance: Double, altitude: Double)] {
        var cumDist = 0.0
        var cumAlt = 0.0
        var lastTime = 0.0
        return samples.map { sample in
            let dt = sample.time - lastTime
            if dt > 0 {
                let segDist = (sample.speed / 3.6) * dt  // km/h to m/s * seconds = meters
                cumDist += segDist
                if sample.incline > 0 {
                    cumAlt += segDist * (sample.incline / 100.0)
                }
            }
            lastTime = sample.time
            return (timeOffset: sample.time, speed: sample.speed, distance: cumDist, altitude: cumAlt)
        }
    }

    private func saveSession(duration: TimeInterval) {
        let startDate = sessionStartDate ?? Date()
        let endDate = Date()
        let distance = state.distance - sessionStartDistance
        let calories = Int32(state.calories - sessionStartCalories)
        let avgSpeed = state.avgSpeed
        let avgIncline = inclineSampleCount > 0 ? inclineSum / Double(inclineSampleCount) : 0
        let elevationGain = WorkoutSession.calculateElevationGain(from: samples)

        // Save to Core Data
        let context = persistence.viewContext
        let session = WorkoutSession(entity: NSEntityDescription.entity(forEntityName: "WorkoutSession", in: context)!, insertInto: context)
        session.id = UUID()
        session.date = startDate
        session.duration = duration
        session.distance = distance
        session.calories = calories
        session.avgSpeed = avgSpeed
        session.maxSpeed = maxSpeed
        session.avgIncline = avgIncline
        session.elevationGain = elevationGain
        session.speedSamples = try? JSONEncoder().encode(samples)

        persistence.save()
        logger.info("Session saved: \(distance)m, \(duration)s")

        // Save to HealthKit
        let hkSamples = samples.map { sample in
            (date: startDate.addingTimeInterval(sample.time), speedKmh: sample.speed)
        }
        Task {
            await HealthKitManager.shared.saveWorkout(
                startDate: startDate,
                endDate: endDate,
                distanceMeters: distance,
                calories: Int(calories),
                avgSpeedKmh: avgSpeed,
                maxSpeedKmh: maxSpeed,
                speedSamples: hkSamples
            )
        }

        // Delayed: fetch HR from HealthKit, then upload to Strava
        let stravaSamples = buildStravaSamples()
        let sessionRef = session.objectID
        let persistenceRef = persistence
        Task {
            // Wait for Apple Watch to flush HR data to HealthKit
            try? await Task.sleep(for: .seconds(15))

            // Fetch HR samples
            let hrRaw = await HealthKitManager.shared.fetchHeartRateSamples(from: startDate, to: endDate)
            let hrSamples = hrRaw.map {
                WorkoutSession.HeartRateSample(time: $0.date.timeIntervalSince(startDate), bpm: $0.bpm)
            }

            // Update Core Data with HR data
            if !hrSamples.isEmpty {
                await MainActor.run {
                    let ctx = persistenceRef.viewContext
                    guard let session = try? ctx.existingObject(with: sessionRef) as? WorkoutSession else { return }
                    let bpms = hrSamples.map(\.bpm)
                    session.avgHeartRate = Double(bpms.reduce(0, +)) / Double(bpms.count)
                    session.maxHeartRate = Double(bpms.max() ?? 0)
                    session.heartRateSamples = try? JSONEncoder().encode(hrSamples)
                    persistenceRef.save()
                }
            }

            // Upload to Strava (with HR if available)
            let hrForStrava = hrSamples.map { (timeOffset: $0.time, bpm: $0.bpm) }
            let activityId = await StravaManager.shared.uploadWorkout(
                startDate: startDate,
                durationSeconds: duration,
                distanceMeters: distance,
                calories: Int(calories),
                speedSamples: stravaSamples,
                heartRateSamples: hrForStrava
            )

            // Store Strava activity ID
            if let activityId {
                await MainActor.run {
                    let ctx = persistenceRef.viewContext
                    guard let session = try? ctx.existingObject(with: sessionRef) as? WorkoutSession else { return }
                    session.stravaActivityId = String(activityId)
                    persistenceRef.save()
                }
            }
        }
    }
}
