// ~/src/tmill/TreadmillTests/SessionTrackerTests.swift
import XCTest
@testable import Treadmill

final class SessionTrackerTests: XCTestCase {

    func testStartsRecordingWhenRunning() {
        let state = TreadmillState()
        let persistence = PersistenceController(inMemory: true)
        let tracker = SessionTracker(state: state, persistence: persistence, minDuration: 10)

        state.isRunning = true
        tracker.check()

        XCTAssertTrue(tracker.isRecording)
    }

    func testStopsAndSavesWhenDurationMet() {
        let state = TreadmillState()
        let persistence = PersistenceController(inMemory: true)
        let tracker = SessionTracker(state: state, persistence: persistence, minDuration: 0)

        // Start with initial values
        state.isRunning = true
        state.speed = 3.5
        state.distance = 0
        state.calories = 0
        tracker.check()

        // Simulate workout progressing
        state.distance = 500
        state.calories = 50
        tracker.recordSample()
        tracker.recordSample()

        // Stop
        state.isRunning = false
        state.elapsed = 120
        tracker.check()

        XCTAssertFalse(tracker.isRecording)

        // Verify saved session
        let request = NSFetchRequest<WorkoutSession>(entityName: "WorkoutSession")
        let sessions = try! persistence.viewContext.fetch(request)
        XCTAssertEqual(sessions.count, 1)
        XCTAssertEqual(sessions.first?.distance ?? 0, 500, accuracy: 0.1)
    }

    func testDiscardsShortSession() {
        let state = TreadmillState()
        let persistence = PersistenceController(inMemory: true)
        let tracker = SessionTracker(state: state, persistence: persistence, minDuration: 300)

        state.isRunning = true
        tracker.check()

        state.isRunning = false
        state.elapsed = 60  // Only 1 minute, below 5 min threshold
        tracker.check()

        let request = NSFetchRequest<WorkoutSession>(entityName: "WorkoutSession")
        let sessions = try! persistence.viewContext.fetch(request)
        XCTAssertEqual(sessions.count, 0)
    }

    func testDisconnectGracePeriod() {
        let state = TreadmillState()
        let persistence = PersistenceController(inMemory: true)
        let tracker = SessionTracker(state: state, persistence: persistence, minDuration: 0)

        // Start session
        state.isRunning = true
        state.elapsed = 600
        state.distance = 1000
        tracker.check()

        // Simulate disconnect (connection drops but isRunning hasn't been cleared by machine status)
        state.connectionStatus = .disconnected
        tracker.handleDisconnect()

        // Should still be recording (grace period)
        XCTAssertTrue(tracker.isRecording)
        XCTAssertTrue(tracker.isInGracePeriod)
    }
}
