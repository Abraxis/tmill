import Foundation
import Observation

enum ConnectionStatus: String {
    case disconnected = "Not Connected"
    case scanning = "Scanning..."
    case connecting = "Connecting..."
    case connected = "Connected"
    case ready = "Ready"
    case unauthorized = "Bluetooth Access Required"
    case poweredOff = "Bluetooth is Off"
}

@Observable
final class MyMillState {
    var connectionStatus: ConnectionStatus = .disconnected
    var speed: Double = 0
    var avgSpeed: Double = 0
    var targetSpeed: Double = 1.0
    var distance: Double = 0
    var elapsed: TimeInterval = 0
    var incline: Double = 0
    var targetIncline: Double = 0
    var calories: Int = 0
    var isRunning: Bool = false
    var isPaused: Bool = false
    var hasControl: Bool = false
    var deviceName: String = ""
    var lastError: String?

    func consumeLastError() -> String? {
        defer { lastError = nil }
        return lastError
    }
    var elevationGain: Double = 0

    /// Reset elevation tracking for a fresh session (not resume)
    func resetElevationTracking() {
        elevationGain = 0
        lastDistance = 0
        wasRunning = false
    }

    /// Count of consecutive zero-speed frames (hysteresis for isRunning)
    private var zeroSpeedCount = 0
    private static let zeroSpeedThreshold = 3
    private var lastDistance: Double = 0
    private var wasRunning: Bool = false

    var isConnected: Bool {
        connectionStatus == .connected || connectionStatus == .ready
    }

    func update(from frame: FTMSProtocol.TreadmillDataFrame) {
        if let s = frame.speed {
            speed = s
            if s > 0 {
                zeroSpeedCount = 0
                isRunning = true
            } else if isRunning {
                // Don't immediately flip to not-running on a single zero frame
                zeroSpeedCount += 1
                if zeroSpeedCount >= MyMillState.zeroSpeedThreshold {
                    isRunning = false
                }
            }
        }
        if let a = frame.avgSpeed { avgSpeed = a }
        if let d = frame.totalDistance { distance = Double(d) }
        if let i = frame.incline { incline = i }
        if let e = frame.totalEnergy { calories = Int(e) }
        if let t = frame.elapsedTime { elapsed = TimeInterval(t) }

        // Elevation gain tracking
        if isRunning {
            if !wasRunning {
                lastDistance = distance
            } else {
                if incline > 0 {
                    let delta = distance - lastDistance
                    if delta > 0 {
                        elevationGain += delta * (incline / 100.0)
                    }
                }
                lastDistance = distance
            }
        }
        if !isRunning && wasRunning && !isPaused {
            lastDistance = 0
        }
        wasRunning = isRunning
    }
}
