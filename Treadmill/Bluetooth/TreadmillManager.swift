import CoreBluetooth
import Foundation
import os

@Observable
final class TreadmillManager: NSObject {
    let state: TreadmillState

    private var centralManager: CBCentralManager!
    private var peripheral: CBPeripheral?
    private var controlPointChar: CBCharacteristic?
    private var reconnectTask: Task<Void, Never>?

    /// Serial queue for BLE control point commands — prevents concurrent sends
    private var pendingResponse: CheckedContinuation<FTMSProtocol.ControlPointResponse?, Never>?
    private var commandLock = false

    private let logger = Logger(subsystem: "com.treadmill.app", category: "BLE")

    init(state: TreadmillState) {
        self.state = state
        super.init()
        print("[BLE] TreadmillManager init — creating CBCentralManager")
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
        print("[BLE] Started scanning for \(FTMSProtocol.deviceNamePrefix)")
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
    }

    func requestControl() async -> Bool {
        guard controlPointChar != nil else {
            print("[BLE WARN] requestControl: no control point characteristic")
            return false
        }
        print("[BLE] Requesting FTMS control...")
        let response = await sendCommand(FTMSProtocol.encodeRequestControl())
        let ok = response?.result == .success
        state.hasControl = ok
        if ok { state.connectionStatus = .ready }
        return ok
    }

    func start() async {
        print("[BLE] start() called — hasControl=\(self.state.hasControl), controlPoint=\(self.controlPointChar != nil)")
        if !state.hasControl { _ = await requestControl() }
        guard controlPointChar != nil else {
            print("[BLE WARN] start: no control point characteristic, aborting")
            return
        }

        // Start belt first, then set speed — treadmill ignores speed when stopped
        print("[BLE] Sending FTMS Start command...")
        let response = await sendCommand(FTMSProtocol.encodeStart())
        if response?.result == .success {
            state.isRunning = true
            print("[BLE] Treadmill started!")

            // Now set target speed so belt actually moves
            let speed = max(state.targetSpeed, FTMSProtocol.speedMin)
            print("[BLE] Setting speed to \(speed) km/h...")
            let speedResp = await sendCommand(FTMSProtocol.encodeSetSpeed(kmh: speed))
            print("[BLE] Speed response: \(String(describing: speedResp?.result))")
            state.targetSpeed = speed
        } else {
            state.lastError = "Start failed"
            print("[BLE WARN] Start failed: \(String(describing: response?.result))")
        }
    }

    func stop() async {
        guard controlPointChar != nil else { return }
        let response = await sendCommand(FTMSProtocol.encodeStop())
        if response?.result == .success {
            state.isRunning = false
        } else {
            state.lastError = "Stop failed"
        }
    }

    func pause() async {
        guard controlPointChar != nil else { return }
        let response = await sendCommand(FTMSProtocol.encodePause())
        if response?.result == .success {
            state.isRunning = false
        } else {
            state.lastError = "Pause failed"
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

    /// Send a command and wait for the control point response.
    /// Only one command can be in flight at a time — waits for previous to finish.
    private func sendCommand(_ data: Data) async -> FTMSProtocol.ControlPointResponse? {
        let hex = data.map { String(format: "%02x", $0) }.joined()
        print("[BLE] sendCommand: \(hex), locked=\(self.commandLock)")

        // Wait for any in-flight command to complete
        while commandLock {
            try? await Task.sleep(for: .milliseconds(50))
        }

        guard let peripheral, let char = controlPointChar else {
            print("[BLE WARN] sendCommand: peripheral or controlPoint is nil")
            return nil
        }

        commandLock = true
        defer { commandLock = false }
        print("[BLE] sendCommand: writing to BLE...")

        let response: FTMSProtocol.ControlPointResponse? = await withCheckedContinuation { continuation in
            pendingResponse = continuation
            peripheral.writeValue(data, for: char, type: .withResponse)

            // Timeout — ensure continuation always resumes
            Task { [weak self] in
                try? await Task.sleep(for: .seconds(5))
                guard let self else { return }
                if let c = self.pendingResponse {
                    self.pendingResponse = nil
                    print("[BLE WARN] Command timed out: \(data.map { String(format: "%02x", $0) }.joined())")
                    c.resume(returning: nil)
                }
            }
        }

        return response
    }

    /// Cancel any pending command (e.g., on disconnect)
    private func cancelPendingCommand() {
        if let c = pendingResponse {
            pendingResponse = nil
            c.resume(returning: nil)
        }
        commandLock = false
    }

    // MARK: - Reconnect

    private func scheduleReconnect() {
        reconnectTask?.cancel()
        reconnectTask = Task {
            var delay: UInt64 = 2
            while !Task.isCancelled {
                print("[BLE] Reconnecting in \(delay)s...")
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
                    print("[BLE] Subscribed to Treadmill Data")
                case FTMSProtocol.controlPointUUID:
                    controlPointChar = char
                    peripheral.setNotifyValue(true, for: char)
                    print("[BLE] Subscribed to Control Point")
                case FTMSProtocol.machineStatusUUID:
                    peripheral.setNotifyValue(true, for: char)
                    print("[BLE] Subscribed to Machine Status")
                case FTMSProtocol.trainingStatusUUID:
                    peripheral.setNotifyValue(true, for: char)
                    print("[BLE] Subscribed to Training Status")
                default:
                    break
                }
            }
        }
    }
}

// MARK: - CBCentralManagerDelegate

extension TreadmillManager: CBCentralManagerDelegate {
    func centralManagerDidUpdateState(_ central: CBCentralManager) {
        print("[BLE] BLE state changed: \(String(describing: central.state.rawValue))")
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
        print("[BLE] Found \(name)")
        central.stopScan()
        self.peripheral = peripheral
        peripheral.delegate = self
        state.connectionStatus = .connecting
        state.deviceName = name
        central.connect(peripheral, options: nil)
    }

    func centralManager(_ central: CBCentralManager, didConnect peripheral: CBPeripheral) {
        print("[BLE] Connected to \(peripheral.name ?? "unknown")")
        state.connectionStatus = .connected
        peripheral.discoverServices(nil)
    }

    func centralManager(_ central: CBCentralManager, didDisconnectPeripheral peripheral: CBPeripheral, error: Error?) {
        print("[BLE WARN] Disconnected: \(error?.localizedDescription ?? "none")")
        controlPointChar = nil
        cancelPendingCommand()
        state.hasControl = false
        let wasRunning = state.isRunning
        state.connectionStatus = .disconnected
        if !wasRunning {
            state.isRunning = false
        }
        scheduleReconnect()
    }

    func centralManager(_ central: CBCentralManager, didFailToConnect peripheral: CBPeripheral, error: Error?) {
        print("[BLE ERROR] Failed to connect: \(error?.localizedDescription ?? "unknown")")
        state.connectionStatus = .disconnected
        scheduleReconnect()
    }
}

// MARK: - CBPeripheralDelegate

extension TreadmillManager: CBPeripheralDelegate {
    func peripheral(_ peripheral: CBPeripheral, didDiscoverServices error: Error?) {
        guard let services = peripheral.services else { return }
        for service in services {
            peripheral.discoverCharacteristics(nil, for: service)
        }
    }

    func peripheral(_ peripheral: CBPeripheral, didDiscoverCharacteristicsFor service: CBService, error: Error?) {
        subscribeToCharacteristics(of: peripheral)
        // requestControl is triggered from didUpdateNotificationStateFor once control point subscription is confirmed
    }

    func peripheral(_ peripheral: CBPeripheral, didUpdateNotificationStateFor characteristic: CBCharacteristic, error: Error?) {
        let uuid = characteristic.uuid.uuidString.uppercased()
        if let error {
            print("[BLE WARN] Notification state error for \(uuid): \(error.localizedDescription)")
            return
        }
        print("[BLE] Notification enabled for \(uuid)")

        // Once control point indications are active, request control
        if uuid == FTMSProtocol.controlPointUUID && !state.hasControl {
            print("[BLE] Control point indications active — requesting control after brief settle...")
            Task {
                // Small delay to let CoreBluetooth fully establish the indication path
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
            // Don't log every data frame (too noisy) — just first one
            break // fall through to decode below
        case FTMSProtocol.controlPointUUID:
            print("[BLE] Control Point response: \(data.map { String(format: "%02x", $0) }.joined())")
        case FTMSProtocol.machineStatusUUID:
            print("[BLE] Machine Status: \(data.map { String(format: "%02x", $0) }.joined())")
        default:
            break
        }

        switch uuid {
        case FTMSProtocol.treadmillDataUUID:
            let frame = FTMSProtocol.decodeTreadmillData(data)
            Task { @MainActor in
                state.update(from: frame)
            }
        case FTMSProtocol.controlPointUUID:
            if let response = FTMSProtocol.decodeControlPointResponse(data) {
                if let c = pendingResponse {
                    pendingResponse = nil
                    c.resume(returning: response)
                }
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
        case 0x04: // Started/Resumed
            Task { @MainActor in state.isRunning = true }
        case 0x02, 0x03: // Stopped/Paused, Stopped by safety
            Task { @MainActor in state.isRunning = false }
        default:
            break
        }
    }
}
