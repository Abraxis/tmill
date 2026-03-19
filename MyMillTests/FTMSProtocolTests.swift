import XCTest
@testable import MyMill

final class FTMSProtocolTests: XCTestCase {

    // MARK: - Decode Treadmill Data

    func testDecodeSpeed() {
        // Flags: bit 0 CLEAR = speed present. Flags = 0x0000
        // Speed: 5.00 km/h = 500 = 0x01F4
        let data = Data([0x00, 0x00, 0xF4, 0x01])
        let frame = FTMSProtocol.decodeTreadmillData(data)
        XCTAssertEqual(frame.speed!, 5.0, accuracy: 0.01)
    }

    func testDecodeAvgSpeed() {
        // Flags: bit 0 CLEAR (speed present) + bit 1 SET (avg speed present) = 0x0002
        // Speed: 3.50 km/h = 350 = 0x015E
        // Avg speed: 4.20 km/h = 420 = 0x01A4
        let data = Data([0x02, 0x00, 0x5E, 0x01, 0xA4, 0x01])
        let frame = FTMSProtocol.decodeTreadmillData(data)
        XCTAssertEqual(frame.speed!, 3.5, accuracy: 0.01)
        XCTAssertEqual(frame.avgSpeed!, 4.2, accuracy: 0.01)
    }

    func testDecodeDistance() {
        // Flags: bit 0 SET (no speed) + bit 2 SET (distance) = 0x0005
        // Distance: 1234 m = 0x0004D2 (24-bit LE)
        let data = Data([0x05, 0x00, 0xD2, 0x04, 0x00])
        let frame = FTMSProtocol.decodeTreadmillData(data)
        XCTAssertNil(frame.speed)
        XCTAssertEqual(frame.totalDistance, 1234)
    }

    func testDecodeIncline() {
        // Flags: bit 0 SET (no speed) + bit 3 SET (incline+ramp) = 0x0009
        // Incline: 5.0% = 50 = 0x0032 (sint16 LE)
        // Ramp angle: 2.8 deg = 28 = 0x001C (sint16 LE)
        let data = Data([0x09, 0x00, 0x32, 0x00, 0x1C, 0x00])
        let frame = FTMSProtocol.decodeTreadmillData(data)
        XCTAssertNil(frame.speed)
        XCTAssertEqual(frame.incline!, 5.0, accuracy: 0.01)
        XCTAssertEqual(frame.rampAngle!, 2.8, accuracy: 0.01)
    }

    func testDecodeEnergy() {
        // Flags: bit 0 SET (no speed) + bit 7 SET (energy) = 0x0081
        // Total energy: 256 kcal = 0x0100
        // Per hour: 0x0000, per minute: 0x00 (skipped)
        let data = Data([0x81, 0x00, 0x00, 0x01, 0x00, 0x00, 0x00])
        let frame = FTMSProtocol.decodeTreadmillData(data)
        XCTAssertEqual(frame.totalEnergy, 256)
    }

    func testDecodeElapsedTime() {
        // Flags: bit 0 SET (no speed) + bit 10 SET (elapsed time) = 0x0401
        // Elapsed time: 600 seconds = 0x0258
        let data = Data([0x01, 0x04, 0x58, 0x02])
        let frame = FTMSProtocol.decodeTreadmillData(data)
        XCTAssertEqual(frame.elapsedTime, 600)
    }

    func testDecodeRemainingTime() {
        // Flags: bit 0 SET (no speed) + bit 11 SET (remaining time) = 0x0801
        // Remaining time: 300 seconds = 0x012C
        let data = Data([0x01, 0x08, 0x2C, 0x01])
        let frame = FTMSProtocol.decodeTreadmillData(data)
        XCTAssertEqual(frame.remainingTime, 300)
    }

    func testDecodeEmptyData() {
        let frame = FTMSProtocol.decodeTreadmillData(Data())
        XCTAssertNil(frame.speed)
        XCTAssertNil(frame.avgSpeed)
        XCTAssertNil(frame.totalDistance)
        XCTAssertNil(frame.incline)
        XCTAssertNil(frame.rampAngle)
        XCTAssertNil(frame.totalEnergy)
        XCTAssertNil(frame.elapsedTime)
        XCTAssertNil(frame.remainingTime)
    }

    // MARK: - Encode Commands

    func testEncodeRequestControl() {
        XCTAssertEqual(FTMSProtocol.encodeRequestControl(), Data([0x00]))
    }

    func testEncodeReset() {
        XCTAssertEqual(FTMSProtocol.encodeReset(), Data([0x01]))
    }

    func testEncodeStart() {
        XCTAssertEqual(FTMSProtocol.encodeStart(), Data([0x07]))
    }

    func testEncodeStop() {
        XCTAssertEqual(FTMSProtocol.encodeStop(), Data([0x08, 0x01]))
    }

    func testEncodePause() {
        XCTAssertEqual(FTMSProtocol.encodePause(), Data([0x08, 0x02]))
    }

    func testEncodeSetSpeed() {
        // 3.5 km/h = 350 = 0x015E
        let data = FTMSProtocol.encodeSetSpeed(kmh: 3.5)
        XCTAssertEqual(data, Data([0x02, 0x5E, 0x01]))
    }

    func testEncodeSetSpeedClampLow() {
        // Below min (1.0) should clamp to 1.0 = 100 = 0x0064
        let data = FTMSProtocol.encodeSetSpeed(kmh: 0.5)
        XCTAssertEqual(data, Data([0x02, 0x64, 0x00]))
    }

    func testEncodeSetSpeedClampHigh() {
        // Above max (6.5) should clamp to 6.5 = 650 = 0x028A
        let data = FTMSProtocol.encodeSetSpeed(kmh: 10.0)
        XCTAssertEqual(data, Data([0x02, 0x8A, 0x02]))
    }

    func testEncodeSetIncline() {
        // 5.0% = 50 = 0x0032
        let data = FTMSProtocol.encodeSetIncline(percent: 5.0)
        XCTAssertEqual(data, Data([0x03, 0x32, 0x00]))
    }

    func testEncodeSetInclineClampLow() {
        // Below min (0.0) should clamp to 0.0 = 0
        let data = FTMSProtocol.encodeSetIncline(percent: -5.0)
        XCTAssertEqual(data, Data([0x03, 0x00, 0x00]))
    }

    func testEncodeSetInclineClampHigh() {
        // Above max (12.0) should clamp to 12.0 = 120 = 0x0078
        let data = FTMSProtocol.encodeSetIncline(percent: 20.0)
        XCTAssertEqual(data, Data([0x03, 0x78, 0x00]))
    }

    // MARK: - Decode Control Point Response

    func testDecodeControlPointResponseSuccess() {
        // Response opcode 0x80, request opcode 0x00 (request control), result 0x01 (success)
        let data = Data([0x80, 0x00, 0x01])
        let response = FTMSProtocol.decodeControlPointResponse(data)
        XCTAssertNotNil(response)
        XCTAssertEqual(response?.requestOpcode, 0x00)
        XCTAssertEqual(response?.result, .success)
    }

    func testDecodeControlPointResponseNotPermitted() {
        let data = Data([0x80, 0x07, 0x05])
        let response = FTMSProtocol.decodeControlPointResponse(data)
        XCTAssertNotNil(response)
        XCTAssertEqual(response?.requestOpcode, 0x07)
        XCTAssertEqual(response?.result, .controlNotPermitted)
    }

    func testDecodeControlPointResponseTooShort() {
        let data = Data([0x80, 0x00])
        let response = FTMSProtocol.decodeControlPointResponse(data)
        XCTAssertNil(response)
    }

    func testDecodeControlPointResponseWrongOpcode() {
        let data = Data([0x07, 0x00, 0x01])
        let response = FTMSProtocol.decodeControlPointResponse(data)
        XCTAssertNil(response)
    }
}
