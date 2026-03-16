import SwiftUI

@main
struct TreadmillApp: App {
    @State private var appState = AppState()

    var body: some Scene {
        MenuBarExtra {
            MenuBarContentView(appState: appState)
        } label: {
            HStack(spacing: 4) {
                Image(systemName: "figure.walk")
                if appState.treadmill.isRunning {
                    Text(String(format: "%.1f", appState.treadmill.speed))
                        .font(.system(.caption, design: .monospaced))
                }
            }
        }

        Window("Workout History", id: "history") {
            HistoryWindow()
                .environment(\.managedObjectContext, appState.persistence.viewContext)
        }

        Window("Edit Programs", id: "programs") {
            ProgramEditorView()
                .environment(\.managedObjectContext, appState.persistence.viewContext)
        }

        Window("Settings", id: "settings") {
            SettingsView()
                .fixedSize()
        }
        .windowResizability(.contentSize)
    }
}

/// Holds all app-level state, initialized eagerly at launch
@Observable
final class AppState {
    let treadmill = TreadmillState()
    let persistence = PersistenceController.shared
    let settings = SettingsManager.shared
    let manager: TreadmillManager
    var sessionTracker: SessionTracker!
    var programEngine: ProgramEngine!

    init() {
        manager = TreadmillManager(state: treadmill)
        programEngine = ProgramEngine(state: treadmill)
        sessionTracker = SessionTracker(
            state: treadmill,
            persistence: persistence,
            minDuration: settings.minSessionDuration
        )

        // Sleep/wake
        let mgr = manager
        let workspace = NSWorkspace.shared
        workspace.notificationCenter.addObserver(
            forName: NSWorkspace.willSleepNotification,
            object: nil, queue: .main
        ) { _ in mgr.disconnect() }
        workspace.notificationCenter.addObserver(
            forName: NSWorkspace.didWakeNotification,
            object: nil, queue: .main
        ) { _ in mgr.startScanning() }

        // Periodic tracking
        Timer.scheduledTimer(withTimeInterval: 5.0, repeats: true) { [weak self] _ in
            guard let self else { return }
            Task { @MainActor in
                self.sessionTracker.check()
                self.sessionTracker.recordSample()
                self.programEngine.updateFromState()
                if let speed = self.programEngine.pendingSpeed {
                    await self.manager.setSpeed(speed)
                    self.programEngine.clearPendingCommands()
                }
                if let incline = self.programEngine.pendingIncline {
                    await self.manager.setIncline(incline)
                    self.programEngine.clearPendingCommands()
                }
                if self.programEngine.shouldStop {
                    await self.manager.stop()
                    self.programEngine.stop()
                }
            }
        }
    }
}

/// Snapshot of treadmill state — captured once when menu opens, prevents live re-renders
struct MenuSnapshot {
    let isConnected: Bool
    let isRunning: Bool
    let connectionStatus: String
    let deviceName: String
    let speed: Double
    let incline: Double
    let distance: Double
    let elapsed: TimeInterval
    let calories: Int
    let targetSpeed: Double
    let targetIncline: Double

    init(from t: TreadmillState) {
        isConnected = t.isConnected
        isRunning = t.isRunning
        connectionStatus = t.connectionStatus.rawValue
        deviceName = t.deviceName
        speed = t.speed
        incline = t.incline
        distance = t.distance
        elapsed = t.elapsed
        calories = t.calories
        targetSpeed = t.targetSpeed
        targetIncline = t.targetIncline
    }

    var statusLine: String {
        if isConnected {
            return "\(deviceName) — \(isRunning ? String(format: "%.1f km/h", speed) : "Idle")"
        }
        return "Treadmill"
    }

    var distanceFormatted: String {
        distance >= 1000 ? String(format: "%.2f km", distance / 1000) : "\(Int(distance)) m"
    }

    var timeFormatted: String {
        let mins = Int(elapsed) / 60
        let secs = Int(elapsed) % 60
        return String(format: "%d:%02d", mins, secs)
    }
}

/// Menu content — snapshot-based to avoid re-renders from live BLE data
struct MenuBarContentView: View {
    let appState: AppState
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        // Snapshot state once when menu opens — no live binding
        let snap = MenuSnapshot(from: appState.treadmill)
        let mgr = appState.manager
        let s = appState.settings

        Text(snap.statusLine)
            .font(.headline)

        Divider()

        if snap.isConnected {
            Text("Speed: \(String(format: "%.1f", snap.speed)) km/h")
            Text("Incline: \(String(format: "%.0f", snap.incline))%")
            Text("Distance: \(snap.distanceFormatted)")
            Text("Time: \(snap.timeFormatted)")
            Text("Calories: \(snap.calories) kcal")

            Divider()

            if snap.isRunning {
                Button("⏹ Stop") { fire { await mgr.stop() } }
                Button("⏸ Pause") { fire { await mgr.pause() } }
            } else {
                Button("▶ Start") { fire { await mgr.start() } }
            }

            Divider()

            Button("Speed + (\(String(format: "%.1f", s.speedIncrement)))") {
                fire { await mgr.setSpeed(snap.targetSpeed + s.speedIncrement) }
            }
            Button("Speed − (\(String(format: "%.1f", s.speedIncrement)))") {
                fire { await mgr.setSpeed(snap.targetSpeed - s.speedIncrement) }
            }
            Button("Incline + (\(String(format: "%.0f", s.inclineIncrement))%)") {
                fire { await mgr.setIncline(snap.targetIncline + s.inclineIncrement) }
            }
            Button("Incline − (\(String(format: "%.0f", s.inclineIncrement))%)") {
                fire { await mgr.setIncline(snap.targetIncline - s.inclineIncrement) }
            }
        } else {
            Text(snap.connectionStatus)
                .foregroundStyle(.secondary)
        }

        Divider()

        Button("Open History...") { activateAndOpen("history") }
            .keyboardShortcut("h")
        Button("Edit Programs...") { activateAndOpen("programs") }
        Button("Settings...") { activateAndOpen("settings") }
            .keyboardShortcut(",")

        Divider()

        Button("Quit Treadmill") { NSApplication.shared.terminate(nil) }
            .keyboardShortcut("q")
    }

    private func fire(_ action: @escaping @Sendable () async -> Void) {
        Task.detached { await action() }
    }

    private func activateAndOpen(_ id: String) {
        NSApplication.shared.activate(ignoringOtherApps: true)
        openWindow(id: id)
    }
}
