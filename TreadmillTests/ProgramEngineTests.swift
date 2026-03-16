// ~/src/tmill/TreadmillTests/ProgramEngineTests.swift
import XCTest
import CoreData
@testable import Treadmill

final class ProgramEngineTests: XCTestCase {

    private var persistence: PersistenceController!
    private var context: NSManagedObjectContext!

    override func setUp() {
        persistence = PersistenceController(inMemory: true)
        context = persistence.viewContext
    }

    private func makeProgram(segments: [(speed: Double, incline: Double, goalType: String, goalValue: Double)]) -> WorkoutProgram {
        let program = WorkoutProgram(entity: NSEntityDescription.entity(forEntityName: "WorkoutProgram", in: context)!, insertInto: context)
        program.id = UUID()
        program.name = "Test"
        program.createdAt = Date()

        let mutableSegments = NSMutableOrderedSet()
        for (i, seg) in segments.enumerated() {
            let s = ProgramSegment(entity: NSEntityDescription.entity(forEntityName: "ProgramSegment", in: context)!, insertInto: context)
            s.id = UUID()
            s.order = Int16(i)
            s.targetSpeed = seg.speed
            s.targetIncline = seg.incline
            s.goalType = seg.goalType
            s.goalValue = seg.goalValue
            s.program = program
            mutableSegments.add(s)
        }
        program.segments = mutableSegments

        return program
    }

    func testStartsSendsFirstSegment() {
        let program = makeProgram(segments: [
            (speed: 3.0, incline: 2.0, goalType: "time", goalValue: 60)
        ])
        let state = TreadmillState()
        let engine = ProgramEngine(state: state)
        engine.loadProgram(program)
        engine.start()

        XCTAssertEqual(engine.currentSegmentIndex, 0)
        XCTAssertTrue(engine.isActive)
        XCTAssertEqual(engine.pendingSpeed, 3.0)
        XCTAssertEqual(engine.pendingIncline, 2.0)
    }

    func testAdvancesOnTimeGoal() {
        let program = makeProgram(segments: [
            (speed: 3.0, incline: 0, goalType: "time", goalValue: 60),
            (speed: 5.0, incline: 5, goalType: "time", goalValue: 120)
        ])
        let state = TreadmillState()
        let engine = ProgramEngine(state: state)
        engine.loadProgram(program)
        engine.start()

        // Simulate 60 seconds passing
        engine.update(elapsedSinceSegmentStart: 60)

        XCTAssertEqual(engine.currentSegmentIndex, 1)
        XCTAssertEqual(engine.pendingSpeed, 5.0)
        XCTAssertEqual(engine.pendingIncline, 5.0)
    }

    func testAdvancesOnDistanceGoal() {
        let program = makeProgram(segments: [
            (speed: 3.0, incline: 0, goalType: "distance", goalValue: 500)
        ])
        let state = TreadmillState()
        let engine = ProgramEngine(state: state)
        engine.loadProgram(program)
        engine.start()

        engine.update(distanceSinceSegmentStart: 500)

        // Should be complete (no more segments)
        XCTAssertTrue(engine.isComplete)
    }

    func testAdvancesOnCalorieGoal() {
        let program = makeProgram(segments: [
            (speed: 4.0, incline: 3, goalType: "calories", goalValue: 50)
        ])
        let state = TreadmillState()
        let engine = ProgramEngine(state: state)
        engine.loadProgram(program)
        engine.start()

        engine.update(caloriesSinceSegmentStart: 50)

        XCTAssertTrue(engine.isComplete)
    }

    func testStopsAfterLastSegment() {
        let program = makeProgram(segments: [
            (speed: 3.0, incline: 0, goalType: "time", goalValue: 10)
        ])
        let state = TreadmillState()
        let engine = ProgramEngine(state: state)
        engine.loadProgram(program)
        engine.start()

        engine.update(elapsedSinceSegmentStart: 10)

        XCTAssertTrue(engine.isComplete)
        XCTAssertFalse(engine.isActive)
        XCTAssertTrue(engine.shouldStop)
    }

    func testProgressCalculation() {
        let program = makeProgram(segments: [
            (speed: 3.0, incline: 0, goalType: "time", goalValue: 100)
        ])
        let state = TreadmillState()
        let engine = ProgramEngine(state: state)
        engine.loadProgram(program)
        engine.start()

        engine.update(elapsedSinceSegmentStart: 45)

        XCTAssertEqual(engine.segmentProgress, 0.45, accuracy: 0.01)
    }
}
