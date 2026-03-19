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

    func testSampleTimesAreRelativeToSessionStart() {
        let state = TreadmillState()
        let persistence = PersistenceController(inMemory: true)
        let tracker = SessionTracker(state: state, persistence: persistence, minDuration: 0)

        // Simulate treadmill already having elapsed time (e.g. from a previous short session)
        state.elapsed = 300
        state.isRunning = true
        state.speed = 5.0
        tracker.check()

        // Record samples with treadmill elapsed time advancing from 300
        state.elapsed = 301
        tracker.recordSample()
        state.elapsed = 302
        tracker.recordSample()

        // Stop session
        state.isRunning = false
        state.elapsed = 310
        state.distance = 100
        tracker.check()

        // Verify the saved session has relative times, not absolute treadmill elapsed
        let request = NSFetchRequest<WorkoutSession>(entityName: "WorkoutSession")
        let sessions = try! persistence.viewContext.fetch(request)
        XCTAssertEqual(sessions.count, 1)

        let session = sessions.first!
        XCTAssertEqual(session.duration, 10, accuracy: 0.1) // 310 - 300 = 10s, not 310s

        // Verify sample times are relative (should start near 0, not 300)
        if let data = session.speedSamples,
           let samples = try? JSONDecoder().decode([WorkoutSession.Sample].self, from: data) {
            XCTAssertEqual(samples[0].time, 1.0, accuracy: 0.1) // 301 - 300 = 1s
            XCTAssertEqual(samples[1].time, 2.0, accuracy: 0.1) // 302 - 300 = 2s
        } else {
            XCTFail("Could not decode speed samples")
        }
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
