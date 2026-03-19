import Foundation

/// Pure FTMS (Fitness Machine Service) protocol encode/decode logic.
/// No CoreBluetooth dependency — all functions operate on raw `Data`.
enum FTMSProtocol {

    // MARK: - GATT UUIDs (16-bit assigned numbers)

    static let treadmillDataUUID    = "2ACD"
    static let controlPointUUID     = "2AD9"
    static let machineStatusUUID    = "2ADA"
    static let trainingStatusUUID   = "2AD3"

    // MARK: - Treadmill limits (Merach T25)

    static let speedMin:   Double = 1.0
    static let speedMax:   Double = 6.5
    static let speedStep:  Double = 0.1
    static let inclineMin: Double = 0.0
    static let inclineMax: Double = 12.0
    static let inclineStep: Double = 1.0

    // MARK: - Device discovery

    static let deviceNamePrefix = "MRK-T25"

    // MARK: - Control Point opcodes (private)

    private static let opRequestControl: UInt8 = 0x00
    private static let opReset:          UInt8 = 0x01
    private static let opSetTargetSpeed: UInt8 = 0x02
    private static let opSetTargetIncline: UInt8 = 0x03
    private static let opStartResume:    UInt8 = 0x07
    private static let opStopPause:      UInt8 = 0x08
    private static let opResponse:       UInt8 = 0x80

    // MARK: - Treadmill Data Frame

    struct TreadmillDataFrame {
        var speed: Double?          // km/h
        var avgSpeed: Double?       // km/h
        var totalDistance: UInt32?   // metres
        var incline: Double?        // percent
        var rampAngle: Double?      // degrees
        var totalEnergy: UInt16?    // kcal
        var elapsedTime: UInt16?    // seconds
        var remainingTime: UInt16?  // seconds
    }

    // MARK: - Control Point Result

    enum ControlPointResult: UInt8 {
        case success             = 0x01
        case notSupported        = 0x02
        case invalidParameter    = 0x03
        case operationFailed     = 0x04
        case controlNotPermitted = 0x05
    }

    struct ControlPointResponse {
        let requestOpcode: UInt8
        let result: ControlPointResult
    }

    // MARK: - Decode

    /// Parse a Treadmill Data characteristic value per FTMS spec (0x2ACD).
    static func decodeTreadmillData(_ data: Data) -> TreadmillDataFrame {
        var frame = TreadmillDataFrame()
        guard data.count >= 2 else { return frame }

        let flags = UInt16(data[0]) | (UInt16(data[1]) << 8)
        var offset = 2

        // Bit 0 CLEAR = instantaneous speed present (inverted flag!)
        if flags & (1 << 0) == 0 {
            if offset + 2 <= data.count {
                let raw = UInt16(data[offset]) | (UInt16(data[offset + 1]) << 8)
                frame.speed = Double(raw) / 100.0
                offset += 2
            }
        }

        // Bit 1 = average speed present
        if flags & (1 << 1) != 0 {
            if offset + 2 <= data.count {
                let raw = UInt16(data[offset]) | (UInt16(data[offset + 1]) << 8)
                frame.avgSpeed = Double(raw) / 100.0
                offset += 2
            }
        }

        // Bit 2 = total distance present (24-bit unsigned)
        if flags & (1 << 2) != 0 {
            if offset + 3 <= data.count {
                let raw = UInt32(data[offset])
                    | (UInt32(data[offset + 1]) << 8)
                    | (UInt32(data[offset + 2]) << 16)
                frame.totalDistance = raw
                offset += 3
            }
        }

        // Bit 3 = inclination + ramp angle present (sint16 each)
        if flags & (1 << 3) != 0 {
            if offset + 4 <= data.count {
                let rawIncline = Int16(bitPattern: UInt16(data[offset]) | (UInt16(data[offset + 1]) << 8))
                frame.incline = Double(rawIncline) / 10.0
                offset += 2
                let rawRamp = Int16(bitPattern: UInt16(data[offset]) | (UInt16(data[offset + 1]) << 8))
                frame.rampAngle = Double(rawRamp) / 10.0
                offset += 2
            }
        }

        // Bit 4 = positive elevation gain (skip 4 bytes: uint16 + uint16)
        if flags & (1 << 4) != 0 {
            offset += 4
        }

        // Bit 5 = instantaneous pace (uint8 per FTMS spec — 1 byte, units: km/min with 0.1 resolution)
        if flags & (1 << 5) != 0 {
            offset += 1
        }

        // Bit 6 = average pace (uint8 per FTMS spec — 1 byte, units: km/min with 0.1 resolution)
        if flags & (1 << 6) != 0 {
            offset += 1
        }

        // Bit 7 = expended energy present (uint16 total + uint16 per hour + uint8 per minute)
        if flags & (1 << 7) != 0 {
            if offset + 5 <= data.count {
                let raw = UInt16(data[offset]) | (UInt16(data[offset + 1]) << 8)
                frame.totalEnergy = raw
                offset += 5 // skip total(2) + per_hour(2) + per_minute(1)
            }
        }

        // Bit 8 = heart rate (skip 1 byte: uint8)
        if flags & (1 << 8) != 0 {
            offset += 1
        }

        // Bit 9 = metabolic equivalent (skip 1 byte: uint8)
        if flags & (1 << 9) != 0 {
            offset += 1
        }

        // Bit 10 = elapsed time present (uint16)
        if flags & (1 << 10) != 0 {
            if offset + 2 <= data.count {
                let raw = UInt16(data[offset]) | (UInt16(data[offset + 1]) << 8)
                frame.elapsedTime = raw
                offset += 2
            }
        }

        // Bit 11 = remaining time present (uint16)
        if flags & (1 << 11) != 0 {
            if offset + 2 <= data.count {
                let raw = UInt16(data[offset]) | (UInt16(data[offset + 1]) << 8)
                frame.remainingTime = raw
                offset += 2
            }
        }

        return frame
    }

    /// Parse a Fitness Machine Control Point response (0x2AD9 indication).
    static func decodeControlPointResponse(_ data: Data) -> ControlPointResponse? {
        guard data.count >= 3, data[0] == opResponse else { return nil }
        guard let result = ControlPointResult(rawValue: data[2]) else { return nil }
        return ControlPointResponse(requestOpcode: data[1], result: result)
    }

    // MARK: - Encode

    static func encodeRequestControl() -> Data {
        Data([opRequestControl])
    }

    static func encodeReset() -> Data {
        Data([opReset])
    }

    static func encodeStart() -> Data {
        Data([opStartResume])
    }

    static func encodeStop() -> Data {
        Data([opStopPause, 0x01])
    }

    static func encodePause() -> Data {
        Data([opStopPause, 0x02])
    }

    static func encodeSetSpeed(kmh: Double) -> Data {
        let clamped = min(max(kmh, speedMin), speedMax)
        let rounded = (clamped / speedStep).rounded() * speedStep
        let raw = UInt16(round(rounded * 100.0))
        return Data([opSetTargetSpeed, UInt8(raw & 0xFF), UInt8(raw >> 8)])
    }

    static func encodeSetIncline(percent: Double) -> Data {
        let clamped = min(max(percent, inclineMin), inclineMax)
        let rounded = (clamped / inclineStep).rounded() * inclineStep
        let raw = Int16(round(rounded * 10.0))
        let unsigned = UInt16(bitPattern: raw)
        return Data([opSetTargetIncline, UInt8(unsigned & 0xFF), UInt8(unsigned >> 8)])
    }
}
