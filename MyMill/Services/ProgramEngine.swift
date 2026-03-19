// Services/ProgramEngine.swift
import Foundation
import os

@Observable
final class ProgramEngine {
    private(set) var isActive = false
    private(set) var isComplete = false
    private(set) var shouldStop = false
    private(set) var currentSegmentIndex = 0
    private(set) var segmentProgress: Double = 0
    private(set) var pendingSpeed: Double?
    private(set) var pendingIncline: Double?

    func clearPendingCommands() {
        pendingSpeed = nil
        pendingIncline = nil
    }

    private let state: MyMillState
    private var segments: [ProgramSegment] = []
    private var segmentStartDistance: Double = 0
    private var segmentStartCalories: Int = 0
    private var segmentStartTime: TimeInterval = 0

    private let logger = Logger(subsystem: "com.mymill.app", category: "ProgramEngine")

    init(state: MyMillState) {
        self.state = state
    }

    var totalSegments: Int { segments.count }

    var currentSegment: ProgramSegment? {
        guard currentSegmentIndex < segments.count else { return nil }
        return segments[currentSegmentIndex]
    }

    var programName: String? {
        segments.first?.program?.name
    }

    func loadProgram(_ program: WorkoutProgram) {
        segments = program.sortedSegments
        currentSegmentIndex = 0
        isActive = false
        isComplete = false
        shouldStop = false
    }

    func start() {
        guard !segments.isEmpty else { return }
        isActive = true
        isComplete = false
        shouldStop = false
        currentSegmentIndex = 0
        beginSegment()
    }

    func stop() {
        isActive = false
        isComplete = false
        pendingSpeed = nil
        pendingIncline = nil
    }

    /// Called periodically to check segment goal progress.
    /// Pass deltas since current segment started.
    func update(elapsedSinceSegmentStart: TimeInterval = 0,
                distanceSinceSegmentStart: Double = 0,
                caloriesSinceSegmentStart: Int = 0) {
        guard isActive, let segment = currentSegment else { return }

        let goal = segment.goalValue
        var progress: Double = 0

        switch segment.goalTypeEnum {
        case .time:
            progress = elapsedSinceSegmentStart / goal
        case .distance:
            progress = distanceSinceSegmentStart / goal
        case .calories:
            progress = Double(caloriesSinceSegmentStart) / goal
        }

        segmentProgress = min(progress, 1.0)

        if progress >= 1.0 {
            advanceSegment()
        }
    }

    /// Update using live state deltas (for integration with SessionTracker timer).
    func updateFromState() {
        guard isActive else { return }
        let elapsed = state.elapsed - segmentStartTime
        let distance = state.distance - segmentStartDistance
        let calories = state.calories - segmentStartCalories
        update(elapsedSinceSegmentStart: elapsed,
               distanceSinceSegmentStart: distance,
               caloriesSinceSegmentStart: calories)
    }

    // MARK: - Private

    private func beginSegment() {
        guard let segment = currentSegment else { return }
        segmentStartTime = state.elapsed
        segmentStartDistance = state.distance
        segmentStartCalories = state.calories
        segmentProgress = 0
        pendingSpeed = segment.targetSpeed
        pendingIncline = segment.targetIncline
        logger.info("Segment \(self.currentSegmentIndex + 1)/\(self.segments.count): speed=\(segment.targetSpeed), incline=\(segment.targetIncline)")
    }

    private func advanceSegment() {
        currentSegmentIndex += 1
        if currentSegmentIndex >= segments.count {
            logger.info("Program complete")
            isActive = false
            isComplete = true
            shouldStop = true
            pendingSpeed = nil
            pendingIncline = nil
        } else {
            beginSegment()
        }
    }
}
