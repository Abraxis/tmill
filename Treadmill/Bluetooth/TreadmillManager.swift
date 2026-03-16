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
    private var controlContinuation: CheckedContinuation<FTMSProtocol.ControlPointResponse?, Never>?

    private let logger = Logger(subsystem: "com.treadmill.app", category: "BLE")

    init(state: TreadmillState) {
        self.state = state
        super.init()
        centralManager = CBCentralManager(delegate: self, queue: nil)
    }

    func startScanning() {
        guard centralManager.state == .poweredOn else { return }
        state.connectionStatus = .scanning
        centralManager.scanForPeripherals(
            withServices: nil,
            options: [CBCentralManagerScanOptionAllowDuplicatesKey: false]
        )
        logger.info("Started scanning for \(FTMSProtocol.deviceNamePrefix)")
    }

    func disconnect() {
        reconnectTask?.cancel()
        reconnectTask = nil
        if let p = peripheral {
            centralManager.cancelPeripheralConnection(p)
        }
        peripheral = nil
        controlPointChar = nil
        state.connectionStatus = .disconnected
        state.hasControl = false
        state.isRunning = false
    }

    func requestControl() async -> Bool {
        guard let char = controlPointChar else { return false }
        let data = FTMSProtocol.encodeRequestControl()
        let response = await sendControlPoint(data, on: char)
        let ok = response?.result == .success
        state.hasControl = ok
        if ok { state.connectionStatus = .ready }
        return ok
    }

    func start() async {
        if !state.hasControl { _ = await requestControl() }
        guard let char = controlPointChar else { return }
        let response = await sendControlPoint(FTMSProtocol.encodeStart(), on: char)
        if response?.result == .success {
            state.isRunning = true
        } else {
            state.lastError = "Start failed"
        }
    }

    func stop() async {
        guard let char = controlPointChar else { return }
        let response = await sendControlPoint(FTMSProtocol.encodeStop(), on: char)
        if response?.result == .success {
            state.isRunning = false
        } else {
            state.lastError = "Stop failed"
        }
    }

    func pause() async {
        guard let char = controlPointChar else { return }
        let response = await sendControlPoint(FTMSProtocol.encodePause(), on: char)
        if response?.result == .success {
            state.isRunning = false
        } else {
            state.lastError = "Pause failed"
        }
    }

    func setSpeed(_ kmh: Double) async {
        if !state.hasControl { _ = await requestControl() }
        guard let char = controlPointChar else { return }
        let clamped = max(FTMSProtocol.speedMin, min(FTMSProtocol.speedMax, kmh))
        state.targetSpeed = clamped
        let data = FTMSProtocol.encodeSetSpeed(kmh: clamped)
        let response = await sendControlPoint(data, on: char)
        if response?.result != .success {
            state.lastError = "Speed change failed"
        }
    }

    func setIncline(_ percent: Double) async {
        if !state.hasControl { _ = await requestControl() }
        guard let char = controlPointChar else { return }
        let clamped = max(FTMSProtocol.inclineMin, min(FTMSProtocol.inclineMax, percent))
        state.targetIncline = clamped
        let data = FTMSProtocol.encodeSetIncline(percent: clamped)
        let response = await sendControlPoint(data, on: char)
        if response?.result != .success {
            state.lastError = "Incline change failed"
        }
    }

    private func sendControlPoint(_ data: Data, on char: CBCharacteristic) async -> FTMSProtocol.ControlPointResponse? {
        guard let peripheral else { return nil }
        return await withCheckedContinuation { continuation in
            self.controlContinuation = continuation
            peripheral.writeValue(data, for: char, type: .withResponse)
            Task {
                try? await Task.sleep(for: .seconds(5))
                if let c = self.controlContinuation {
                    self.controlContinuation = nil
                    c.resume(returning: nil)
                }
            }
        }
    }

    private func scheduleReconnect() {
        reconnectTask?.cancel()
        reconnectTask = Task {
            var delay: UInt64 = 2
            while !Task.isCancelled {
                logger.info("Reconnecting in \(delay)s...")
                try? await Task.sleep(for: .seconds(delay))
                guard !Task.isCancelled else { break }
                if centralManager.state == .poweredOn {
                    startScanning()
                    break
                }
                delay = min(delay * 2, 30)
            }
        }
    }

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

extension TreadmillManager: CBCentralManagerDelegate {
    func centralManagerDidUpdateState(_ central: CBCentralManager) {
        switch central.state {
        case .poweredOn: startScanning()
        case .poweredOff: state.connectionStatus = .poweredOff
        case .unauthorized: state.connectionStatus = .unauthorized
        default: state.connectionStatus = .disconnected
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
        state.hasControl = false
        let wasRunning = state.isRunning
        if wasRunning {
            state.connectionStatus = .disconnected
        } else {
            state.connectionStatus = .disconnected
            state.isRunning = false
        }
        scheduleReconnect()
    }

    func centralManager(_ central: CBCentralManager, didFailToConnect peripheral: CBPeripheral, error: Error?) {
        state.connectionStatus = .disconnected
        scheduleReconnect()
    }
}

extension TreadmillManager: CBPeripheralDelegate {
    func peripheral(_ peripheral: CBPeripheral, didDiscoverServices error: Error?) {
        guard let services = peripheral.services else { return }
        for service in services {
            peripheral.discoverCharacteristics(nil, for: service)
        }
    }

    func peripheral(_ peripheral: CBPeripheral, didDiscoverCharacteristicsFor service: CBService, error: Error?) {
        subscribeToCharacteristics(of: peripheral)
        Task { _ = await requestControl() }
    }

    func peripheral(_ peripheral: CBPeripheral, didUpdateValueFor characteristic: CBCharacteristic, error: Error?) {
        guard let data = characteristic.value else { return }
        let uuid = characteristic.uuid.uuidString.uppercased()
        switch uuid {
        case FTMSProtocol.treadmillDataUUID:
            let frame = FTMSProtocol.decodeTreadmillData(data)
            Task { @MainActor in state.update(from: frame) }
        case FTMSProtocol.controlPointUUID:
            if let response = FTMSProtocol.decodeControlPointResponse(data),
               let c = controlContinuation {
                controlContinuation = nil
                c.resume(returning: response)
            }
        case FTMSProtocol.machineStatusUUID:
            handleMachineStatus(data)
        default: break
        }
    }

    private func handleMachineStatus(_ data: Data) {
        guard !data.isEmpty else { return }
        switch data[0] {
        case 0x04: Task { @MainActor in state.isRunning = true }
        case 0x02, 0x03: Task { @MainActor in state.isRunning = false }
        default: break
        }
    }
}
