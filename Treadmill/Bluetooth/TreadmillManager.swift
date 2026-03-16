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
    private var pendingResponse: CheckedContinuation<FTMSProtocol.ControlPointResponse?, Never>?
    private var commandLock = false

    private let logger = Logger(subsystem: "com.treadmill.app", category: "BLE")

    init(state: TreadmillState) {
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
        if !state.hasControl { _ = await requestControl() }
        guard controlPointChar != nil else { return }

        let response = await sendCommand(FTMSProtocol.encodeStart())
        if response?.result == .success {
            state.isRunning = true
            // Set target speed after start — treadmill ignores speed when stopped
            let speed = max(state.targetSpeed, FTMSProtocol.speedMin)
            _ = await sendCommand(FTMSProtocol.encodeSetSpeed(kmh: speed))
            state.targetSpeed = speed
        } else {
            state.lastError = "Start failed"
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

    private func sendCommand(_ data: Data) async -> FTMSProtocol.ControlPointResponse? {
        while commandLock {
            try? await Task.sleep(for: .milliseconds(50))
        }

        guard let peripheral, let char = controlPointChar else { return nil }

        commandLock = true
        defer { commandLock = false }

        let response: FTMSProtocol.ControlPointResponse? = await withCheckedContinuation { continuation in
            pendingResponse = continuation
            peripheral.writeValue(data, for: char, type: .withResponse)

            Task { [weak self] in
                try? await Task.sleep(for: .seconds(5))
                guard let self else { return }
                if let c = self.pendingResponse {
                    self.pendingResponse = nil
                    c.resume(returning: nil)
                }
            }
        }

        return response
    }

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

extension TreadmillManager: CBCentralManagerDelegate {
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
        let wasRunning = state.isRunning
        state.connectionStatus = .disconnected
        if !wasRunning {
            state.isRunning = false
        }
        scheduleReconnect()
    }

    func centralManager(_ central: CBCentralManager, didFailToConnect peripheral: CBPeripheral, error: Error?) {
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
        case 0x04:
            Task { @MainActor in state.isRunning = true }
        case 0x02, 0x03:
            Task { @MainActor in state.isRunning = false }
        default:
            break
        }
    }
}
