import CoreBluetooth
import Foundation
import os

@Observable
final class MyMillManager: NSObject {
    let state: MyMillState

    private var centralManager: CBCentralManager!
    private var peripheral: CBPeripheral?
    private var controlPointChar: CBCharacteristic?
    private var reconnectTask: Task<Void, Never>?
    private var pendingResponse: CheckedContinuation<FTMSProtocol.ControlPointResponse?, Never>?
    private let commandLock = NSLock()
    private var commandInFlight = false

    private let logger = Logger(subsystem: "com.mymill.app", category: "BLE")

    init(state: MyMillState) {
        self.state = state
        super.init()
        centralManager = CBCentralManager(delegate: self, queue: nil)
    }

    // MARK: - Public API

    func startScanning() {
        guard centralManager != nil, centralManager.state == .poweredOn else { return }
        state.connectionStatus = .scanning
        centralManager.scanForPeripherals(
            withServices: nil,
            options: [CBCentralManagerScanOptionAllowDuplicatesKey: false]
        )
    }

    func disconnect() {
        reconnectTask?.cancel()
        reconnectTask = nil
        if let p = peripheral {
            centralManager?.cancelPeripheralConnection(p)
        }
        peripheral = nil
        controlPointChar = nil
        cancelPendingCommand()
        state.connectionStatus = .disconnected
        state.hasControl = false
        state.isRunning = false
        state.isPaused = false
    }

    func requestControl() async -> Bool {
        guard controlPointChar != nil else { return false }
        let response = await sendCommand(FTMSProtocol.encodeRequestControl())
        let ok = response?.result == .success
        state.hasControl = ok
        if ok { state.connectionStatus = .ready }
        return ok
    }

    func start() async {
        guard controlPointChar != nil else {
            state.lastError = "Not connected — turn on treadmill"
            return
        }

        // Ensure we have FTMS control
        if !state.hasControl {
            _ = await requestControl()
        }

        // Try to wake treadmill from standby with Reset before Start.
        // The Merach T25 is BLE-connected in standby but needs activation.
        _ = await sendCommand(FTMSProtocol.encodeReset())
        try? await Task.sleep(for: .milliseconds(500))

        // Re-request control after reset (reset may drop it)
        _ = await requestControl()

        // Send start command
        let response = await sendCommand(FTMSProtocol.encodeStart())
        if response?.result == .success {
            state.isRunning = true
            state.isPaused = false
            // Clear elevation for fresh session (not called on resume)
            state.resetElevationTracking()
            // Set target speed — treadmill ignores speed when stopped
            let speed = max(state.targetSpeed, FTMSProtocol.speedMin)
            _ = await sendCommand(FTMSProtocol.encodeSetSpeed(kmh: speed))
            state.targetSpeed = speed

            // Verify belt actually started
            Task {
                try? await Task.sleep(for: .seconds(4))
                if state.speed == 0 && state.isRunning {
                    state.lastError = "Belt not moving — press power on remote first"
                }
            }
        } else if response == nil {
            state.lastError = "No response — press power button on remote"
        } else {
            state.lastError = "Start failed — press power button on remote first"
        }
    }

    func stop() async {
        guard controlPointChar != nil else { return }
        let response = await sendCommand(FTMSProtocol.encodeStop())
        if response?.result == .success {
            state.isRunning = false
            state.isPaused = false
        } else {
            state.lastError = "Stop failed"
        }
    }

    func pause() async {
        guard controlPointChar != nil else { return }
        let response = await sendCommand(FTMSProtocol.encodePause())
        if response?.result == .success {
            state.isRunning = false
            state.isPaused = true
        } else {
            state.lastError = "Pause failed"
        }
    }

    func resume() async {
        guard controlPointChar != nil else { return }
        if !state.hasControl {
            _ = await requestControl()
        }
        let response = await sendCommand(FTMSProtocol.encodeStart())
        if response?.result == .success {
            state.isRunning = true
            state.isPaused = false
            // Re-apply target speed (belt was stopped during pause)
            let speed = max(state.targetSpeed, FTMSProtocol.speedMin)
            _ = await sendCommand(FTMSProtocol.encodeSetSpeed(kmh: speed))
            // Re-apply target incline (treadmill may reset it on pause)
            if state.targetIncline > 0 {
                _ = await sendCommand(FTMSProtocol.encodeSetIncline(percent: state.targetIncline))
            }
        } else {
            state.lastError = "Resume failed"
        }
    }

    func setSpeed(_ kmh: Double) async {
        if !state.hasControl { _ = await requestControl() }
        guard controlPointChar != nil else { return }
        let clamped = max(FTMSProtocol.speedMin, min(FTMSProtocol.speedMax, kmh))
        state.targetSpeed = clamped
        let response = await sendCommand(FTMSProtocol.encodeSetSpeed(kmh: clamped))
        if response?.result != .success {
            state.lastError = "Speed change failed"
        }
    }

    func setIncline(_ percent: Double) async {
        if !state.hasControl { _ = await requestControl() }
        guard controlPointChar != nil else { return }
        let clamped = max(FTMSProtocol.inclineMin, min(FTMSProtocol.inclineMax, percent))
        state.targetIncline = clamped
        let response = await sendCommand(FTMSProtocol.encodeSetIncline(percent: clamped))
        if response?.result != .success {
            state.lastError = "Incline change failed"
        }
    }

    // MARK: - Command Serialization

    private func sendCommand(_ data: Data) async -> FTMSProtocol.ControlPointResponse? {
        // Serialize commands — wait for any in-flight command to finish
        while true {
            commandLock.lock()
            if !commandInFlight {
                commandInFlight = true
                commandLock.unlock()
                break
            }
            commandLock.unlock()
            try? await Task.sleep(for: .milliseconds(50))
        }

        defer {
            commandLock.lock()
            commandInFlight = false
            commandLock.unlock()
        }

        guard let peripheral, let char = controlPointChar else { return nil }

        let response: FTMSProtocol.ControlPointResponse? = await withCheckedContinuation { continuation in
            pendingResponse = continuation
            peripheral.writeValue(data, for: char, type: .withResponse)

            // Timeout: resume with nil if no BLE response within 5s
            Task { [weak self] in
                try? await Task.sleep(for: .seconds(5))
                guard let self else { return }
                self.resumePendingResponse(with: nil)
            }
        }

        return response
    }

    /// Thread-safe resume of pendingResponse — prevents double-resume crash
    private func resumePendingResponse(with value: FTMSProtocol.ControlPointResponse?) {
        commandLock.lock()
        let continuation = pendingResponse
        pendingResponse = nil
        commandLock.unlock()
        continuation?.resume(returning: value)
    }

    private func cancelPendingCommand() {
        resumePendingResponse(with: nil)
        commandLock.lock()
        commandInFlight = false
        commandLock.unlock()
    }

    // MARK: - Reconnect

    private func scheduleReconnect() {
        reconnectTask?.cancel()
        reconnectTask = Task {
            var delay: UInt64 = 2
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(delay))
                guard !Task.isCancelled else { break }
                if centralManager?.state == .poweredOn {
                    startScanning()
                    break
                }
                delay = min(delay * 2, 30)
            }
        }
    }

    // MARK: - Characteristic Discovery

    private func subscribeToCharacteristics(of peripheral: CBPeripheral) {
        guard let services = peripheral.services else { return }
        for service in services {
            guard let chars = service.characteristics else { continue }
            for char in chars {
                let uuid = char.uuid.uuidString.uppercased()
                switch uuid {
                case FTMSProtocol.treadmillDataUUID:
                    peripheral.setNotifyValue(true, for: char)
                case FTMSProtocol.controlPointUUID:
                    controlPointChar = char
                    peripheral.setNotifyValue(true, for: char)
                case FTMSProtocol.machineStatusUUID:
                    peripheral.setNotifyValue(true, for: char)
                case FTMSProtocol.trainingStatusUUID:
                    peripheral.setNotifyValue(true, for: char)
                default:
                    break
                }
            }
        }
    }
}

// MARK: - CBCentralManagerDelegate

extension MyMillManager: CBCentralManagerDelegate {
    func centralManagerDidUpdateState(_ central: CBCentralManager) {
        switch central.state {
        case .poweredOn:
            startScanning()
        case .poweredOff:
            state.connectionStatus = .poweredOff
        case .unauthorized:
            state.connectionStatus = .unauthorized
        default:
            state.connectionStatus = .disconnected
        }
    }

    func centralManager(_ central: CBCentralManager, didDiscover peripheral: CBPeripheral,
                        advertisementData: [String: Any], rssi RSSI: NSNumber) {
        guard let name = peripheral.name, name.hasPrefix(FTMSProtocol.deviceNamePrefix) else { return }
        central.stopScan()
        self.peripheral = peripheral
        peripheral.delegate = self
        state.connectionStatus = .connecting
        state.deviceName = name
        central.connect(peripheral, options: nil)
    }

    func centralManager(_ central: CBCentralManager, didConnect peripheral: CBPeripheral) {
        state.connectionStatus = .connected
        peripheral.discoverServices(nil)
    }

    func centralManager(_ central: CBCentralManager, didDisconnectPeripheral peripheral: CBPeripheral, error: Error?) {
        controlPointChar = nil
        cancelPendingCommand()
        state.hasControl = false
        state.connectionStatus = .disconnected
        state.isRunning = false
        state.isPaused = false
        scheduleReconnect()
    }

    func centralManager(_ central: CBCentralManager, didFailToConnect peripheral: CBPeripheral, error: Error?) {
        state.connectionStatus = .disconnected
        scheduleReconnect()
    }
}

// MARK: - CBPeripheralDelegate

extension MyMillManager: CBPeripheralDelegate {
    func peripheral(_ peripheral: CBPeripheral, didDiscoverServices error: Error?) {
        guard let services = peripheral.services else { return }
        for service in services {
            peripheral.discoverCharacteristics(nil, for: service)
        }
    }

    func peripheral(_ peripheral: CBPeripheral, didDiscoverCharacteristicsFor service: CBService, error: Error?) {
        subscribeToCharacteristics(of: peripheral)
    }

    func peripheral(_ peripheral: CBPeripheral, didUpdateNotificationStateFor characteristic: CBCharacteristic, error: Error?) {
        guard error == nil else { return }
        let uuid = characteristic.uuid.uuidString.uppercased()
        if uuid == FTMSProtocol.controlPointUUID && !state.hasControl {
            Task {
                try? await Task.sleep(for: .seconds(1))
                _ = await requestControl()
            }
        }
    }

    func peripheral(_ peripheral: CBPeripheral, didUpdateValueFor characteristic: CBCharacteristic, error: Error?) {
        guard let data = characteristic.value else { return }
        let uuid = characteristic.uuid.uuidString.uppercased()

        switch uuid {
        case FTMSProtocol.treadmillDataUUID:
            let frame = FTMSProtocol.decodeTreadmillData(data)
            Task { @MainActor in
                state.update(from: frame)
            }
        case FTMSProtocol.controlPointUUID:
            if let response = FTMSProtocol.decodeControlPointResponse(data) {
                resumePendingResponse(with: response)
            }
        case FTMSProtocol.machineStatusUUID:
            handleMachineStatus(data)
        default:
            break
        }
    }

    private func handleMachineStatus(_ data: Data) {
        guard !data.isEmpty else { return }
        switch data[0] {
        case 0x04:
            Task { @MainActor in
                state.isRunning = true
                state.isPaused = false
            }
        case 0x02: // stop
            Task { @MainActor in
                state.isRunning = false
                // Don't clear isPaused — it's managed by pause()/resume()/stop()
                // Clearing it here causes stopRecording() to fire during a paused session,
                // which resets elevation gain when the user resumes.
            }
        case 0x03: // pause
            Task { @MainActor in
                state.isRunning = false
                state.isPaused = true
            }
        default:
            break
        }
    }
}
