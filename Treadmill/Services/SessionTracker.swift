// ~/src/tmill/Treadmill/Services/SessionTracker.swift
import CoreData
import Foundation
import os

@Observable
final class SessionTracker {
    private(set) var isRecording = false
    private(set) var isInGracePeriod = false

    private let state: TreadmillState
    private let persistence: PersistenceController
    private let minDuration: TimeInterval
    private let gracePeriodDuration: TimeInterval = 60

    private var sessionStartDate: Date?
    private var samples: [WorkoutSession.Sample] = []
    private var maxSpeed: Double = 0
    private var inclineSum: Double = 0
    private var inclineSampleCount: Int = 0
    private var sessionStartDistance: Double = 0
    private var sessionStartCalories: Int = 0
    private var gracePeriodTimer: Task<Void, Never>?
    private var wasRunning = false

    private let logger = Logger(subsystem: "com.treadmill.app", category: "SessionTracker")

    init(state: TreadmillState, persistence: PersistenceController, minDuration: TimeInterval = 300) {
        self.state = state
        self.persistence = persistence
        self.minDuration = minDuration
    }

    /// Call periodically (e.g., every second) or on state changes.
    func check() {
        let running = state.isRunning

        if running && !isRecording && !isInGracePeriod {
            startRecording()
        } else if !running && isRecording && !isInGracePeriod {
            stopRecording()
        }

        wasRunning = running
    }

    func recordSample() {
        guard isRecording else { return }
        let sample = WorkoutSession.Sample(
            time: state.elapsed,
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

    func handleDisconnect() {
        guard isRecording else { return }
        isInGracePeriod = true
        gracePeriodTimer = Task {
            try? await Task.sleep(for: .seconds(gracePeriodDuration))
            guard !Task.isCancelled else { return }
            await MainActor.run {
                // Grace period expired — finalize session
                self.isInGracePeriod = false
                self.stopRecording()
            }
        }
    }

    func handleReconnect() {
        guard isInGracePeriod else { return }
        gracePeriodTimer?.cancel()
        gracePeriodTimer = nil
        isInGracePeriod = false

        if !state.isRunning {
            stopRecording()
        }
        // If still running, session continues seamlessly
    }

    // MARK: - Private

    private func startRecording() {
        isRecording = true
        sessionStartDate = Date()
        sessionStartDistance = state.distance
        sessionStartCalories = state.calories
        samples = []
        maxSpeed = 0
        inclineSum = 0
        inclineSampleCount = 0
        logger.info("Session recording started")
    }

    private func stopRecording() {
        isRecording = false
        let duration = state.elapsed
        logger.info("Session recording stopped, duration: \(duration)s")

        guard duration >= minDuration else {
            logger.info("Session too short (\(duration)s < \(self.minDuration)s), discarding")
            return
        }

        saveSession(duration: duration)
    }

    private func saveSession(duration: TimeInterval) {
        let context = persistence.viewContext
        let session = WorkoutSession(entity: NSEntityDescription.entity(forEntityName: "WorkoutSession", in: context)!, insertInto: context)
        session.id = UUID()
        session.date = sessionStartDate ?? Date()
        session.duration = duration
        session.distance = state.distance - sessionStartDistance
        session.calories = Int32(state.calories - sessionStartCalories)
        session.avgSpeed = state.avgSpeed
        session.maxSpeed = maxSpeed
        session.avgIncline = inclineSampleCount > 0 ? inclineSum / Double(inclineSampleCount) : 0
        session.speedSamples = try? JSONEncoder().encode(samples)

        persistence.save()
        logger.info("Session saved: \(session.distance)m, \(session.duration)s")
    }
}
