// Services/SessionTracker.swift
import CoreData
import Foundation
import os

@Observable
final class SessionTracker {
    private(set) var isRecording = false
    /// Set when a snapshot write fails — observe this to show an alert
    var snapshotError: String?

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
    private var ticksSinceSnapshot: Int = 0

    private static let snapshotInterval = 5  // every 5 ticks × 2s = 10s
    private static let snapshotURL: URL = {
        let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        let dir = appSupport.appendingPathComponent("MyMill", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent("session_recovery.json")
    }()

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
        } else if !state.isRunning && !state.isPaused && isRecording {
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

        // Periodic snapshot to disk for crash recovery
        ticksSinceSnapshot += 1
        if ticksSinceSnapshot >= Self.snapshotInterval {
            ticksSinceSnapshot = 0
            saveSnapshot()
        }
    }

    // MARK: - Crash Recovery

    /// Check for a recovery snapshot on launch and restore it if found.
    func recoverIfNeeded() {
        let url = Self.snapshotURL
        guard FileManager.default.fileExists(atPath: url.path) else { return }

        do {
            let data = try Data(contentsOf: url)
            let snapshot = try JSONDecoder().decode(SessionSnapshot.self, from: data)
            let duration = snapshot.duration
            guard duration >= minDuration else {
                logger.info("Recovery snapshot too short (\(duration)s), discarding")
                removeSnapshot()
                return
            }

            logger.info("Recovering session: \(snapshot.samples.count) samples, \(duration)s")

            let samples = WorkoutSession.trimTrailingZeros(from: snapshot.samples)
            let elevationGain = WorkoutSession.calculateElevationGain(from: samples)
            let avgIncline = snapshot.inclineSampleCount > 0
                ? snapshot.inclineSum / Double(snapshot.inclineSampleCount) : 0

            let context = persistence.viewContext
            let session = WorkoutSession(
                entity: NSEntityDescription.entity(forEntityName: "WorkoutSession", in: context)!,
                insertInto: context
            )
            session.id = UUID()
            session.date = snapshot.startDate
            session.duration = duration
            session.distance = snapshot.distance
            session.calories = Int32(snapshot.calories)
            session.avgSpeed = snapshot.avgSpeed
            session.maxSpeed = snapshot.maxSpeed
            session.avgIncline = avgIncline
            session.elevationGain = elevationGain
            session.speedSamples = try? JSONEncoder().encode(samples)

            persistence.save()
            logger.info("Recovered session saved: \(snapshot.distance)m, \(duration)s")
        } catch {
            logger.error("Recovery failed: \(error.localizedDescription)")
        }

        removeSnapshot()
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
        ticksSinceSnapshot = 0
        state.elevationGain = 0
        logger.info("Session recording started")
    }

    private func stopRecording() {
        isRecording = false

        // Trim trailing zero-speed samples from hysteresis
        samples = WorkoutSession.trimTrailingZeros(from: samples)

        let duration = state.elapsed - sessionStartElapsed
        logger.info("Session recording stopped, duration: \(duration)s")

        // Clean up snapshot — session is being saved properly
        removeSnapshot()

        guard duration >= minDuration else {
            logger.info("Session too short (\(duration)s < \(self.minDuration)s), discarding")
            return
        }

        saveSession(duration: duration)
    }

    private func saveSnapshot() {
        let snapshot = SessionSnapshot(
            startDate: sessionStartDate ?? Date(),
            duration: state.elapsed - sessionStartElapsed,
            distance: state.distance - sessionStartDistance,
            calories: state.calories - sessionStartCalories,
            avgSpeed: state.avgSpeed,
            maxSpeed: maxSpeed,
            inclineSum: inclineSum,
            inclineSampleCount: inclineSampleCount,
            samples: samples
        )

        do {
            let data = try JSONEncoder().encode(snapshot)
            try data.write(to: Self.snapshotURL, options: .atomic)
        } catch {
            logger.error("Snapshot save failed: \(error.localizedDescription)")
            snapshotError = "Session backup failed: \(error.localizedDescription)"
        }
    }

    private func removeSnapshot() {
        try? FileManager.default.removeItem(at: Self.snapshotURL)
    }

    /// Snapshot of in-progress session data for crash recovery
    private struct SessionSnapshot: Codable {
        let startDate: Date
        let duration: TimeInterval
        let distance: Double
        let calories: Int
        let avgSpeed: Double
        let maxSpeed: Double
        let inclineSum: Double
        let inclineSampleCount: Int
        let samples: [WorkoutSession.Sample]
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
