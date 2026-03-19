import XCTest
@testable import MyMill

final class MyMillStateElevationTests: XCTestCase {

    func testElevationAccumulatesFromDistanceAndIncline() {
        let state = MyMillState()
        // Start running: first frame sets anchor
        state.update(from: FTMSProtocol.TreadmillDataFrame(
            speed: 5.0, avgSpeed: nil, totalDistance: 100,
            incline: 10, totalEnergy: nil, elapsedTime: nil
        ))
        XCTAssertEqual(state.elevationGain, 0, "First frame sets anchor, no gain yet")

        // Second frame: moved 100m at 10% incline -> 10m elevation
        state.update(from: FTMSProtocol.TreadmillDataFrame(
            speed: 5.0, avgSpeed: nil, totalDistance: 200,
            incline: 10, totalEnergy: nil, elapsedTime: nil
        ))
        XCTAssertEqual(state.elevationGain, 10.0, accuracy: 0.01)
    }

    func testElevationDoesNotAccumulateAtZeroIncline() {
        let state = MyMillState()
        state.update(from: FTMSProtocol.TreadmillDataFrame(
            speed: 5.0, avgSpeed: nil, totalDistance: 100,
            incline: 0, totalEnergy: nil, elapsedTime: nil
        ))
        state.update(from: FTMSProtocol.TreadmillDataFrame(
            speed: 5.0, avgSpeed: nil, totalDistance: 200,
            incline: 0, totalEnergy: nil, elapsedTime: nil
        ))
        XCTAssertEqual(state.elevationGain, 0)
    }

    func testElevationPersistsWhenTreadmillStops() {
        let state = MyMillState()
        state.update(from: FTMSProtocol.TreadmillDataFrame(
            speed: 5.0, avgSpeed: nil, totalDistance: 100,
            incline: 10, totalEnergy: nil, elapsedTime: nil
        ))
        state.update(from: FTMSProtocol.TreadmillDataFrame(
            speed: 5.0, avgSpeed: nil, totalDistance: 200,
            incline: 10, totalEnergy: nil, elapsedTime: nil
        ))
        let gained = state.elevationGain
        XCTAssertTrue(gained > 0)

        // Stop — elevation should persist (not reset on pause/stop)
        for _ in 0..<3 {
            state.update(from: FTMSProtocol.TreadmillDataFrame(
                speed: 0, avgSpeed: nil, totalDistance: 200,
                incline: 0, totalEnergy: nil, elapsedTime: nil
            ))
        }
        XCTAssertFalse(state.isRunning)
        XCTAssertEqual(state.elevationGain, gained)
    }

    func testElevationContinuesAccumulatingAfterRestart() {
        let state = MyMillState()
        // First run: 100m at 10% = 10m elevation
        state.update(from: FTMSProtocol.TreadmillDataFrame(
            speed: 5.0, avgSpeed: nil, totalDistance: 400,
            incline: 10, totalEnergy: nil, elapsedTime: nil
        ))
        state.update(from: FTMSProtocol.TreadmillDataFrame(
            speed: 5.0, avgSpeed: nil, totalDistance: 500,
            incline: 10, totalEnergy: nil, elapsedTime: nil
        ))
        let firstGain = state.elevationGain
        XCTAssertEqual(firstGain, 10.0, accuracy: 0.01)

        // Stop
        for _ in 0..<3 {
            state.update(from: FTMSProtocol.TreadmillDataFrame(
                speed: 0, avgSpeed: nil, totalDistance: 500,
                incline: 0, totalEnergy: nil, elapsedTime: nil
            ))
        }

        // Restart — re-anchor, no spurious delta
        state.update(from: FTMSProtocol.TreadmillDataFrame(
            speed: 5.0, avgSpeed: nil, totalDistance: 500,
            incline: 10, totalEnergy: nil, elapsedTime: nil
        ))
        XCTAssertEqual(state.elevationGain, firstGain, "No spurious gain on re-anchor")

        // Second run: 100m at 10% = 10m more
        state.update(from: FTMSProtocol.TreadmillDataFrame(
            speed: 5.0, avgSpeed: nil, totalDistance: 600,
            incline: 10, totalEnergy: nil, elapsedTime: nil
        ))
        XCTAssertEqual(state.elevationGain, 20.0, accuracy: 0.01)
    }
}
