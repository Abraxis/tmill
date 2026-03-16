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
        }
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

/// Menu content — uses fire-and-forget for BLE commands (menu closes on click)
struct MenuBarContentView: View {
    let appState: AppState
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        let t = appState.treadmill

        Text(statusLine)
            .font(.headline)

        Divider()

        if t.isConnected {
            Text("Speed: \(String(format: "%.1f", t.speed)) km/h")
            Text("Incline: \(String(format: "%.0f", t.incline))%")
            Text("Distance: \(formatDistance(t.distance))")
            Text("Time: \(formatTime(t.elapsed))")
            Text("Calories: \(t.calories) kcal")

            Divider()

            Button("▶ Start") { fireCommand { await appState.manager.start() } }
                .disabled(t.isRunning)

            Button("⏹ Stop") { fireCommand { await appState.manager.stop() } }
                .disabled(!t.isRunning)

            Button("⏸ Pause") { fireCommand { await appState.manager.pause() } }
                .disabled(!t.isRunning)

            Divider()

            let s = appState.settings
            Button("Speed + (\(String(format: "%.1f", s.speedIncrement)))") {
                fireCommand { await appState.manager.setSpeed(t.targetSpeed + s.speedIncrement) }
            }

            Button("Speed − (\(String(format: "%.1f", s.speedIncrement)))") {
                fireCommand { await appState.manager.setSpeed(t.targetSpeed - s.speedIncrement) }
            }

            Button("Incline + (\(String(format: "%.0f", s.inclineIncrement))%)") {
                fireCommand { await appState.manager.setIncline(t.targetIncline + s.inclineIncrement) }
            }

            Button("Incline − (\(String(format: "%.0f", s.inclineIncrement))%)") {
                fireCommand { await appState.manager.setIncline(t.targetIncline - s.inclineIncrement) }
            }

            if let engine = appState.programEngine, engine.isActive {
                Divider()
                Text("Program: \(engine.programName ?? "Active")")
                Text("Segment \(engine.currentSegmentIndex + 1)/\(engine.totalSegments) — \(Int(engine.segmentProgress * 100))%")
            }
        } else {
            Text(t.connectionStatus.rawValue)
                .foregroundStyle(.secondary)
        }

        Divider()

        Button("Open History...") { openWindow(id: "history") }
            .keyboardShortcut("h")
        Button("Edit Programs...") { openWindow(id: "programs") }
        Button("Settings...") { openWindow(id: "settings") }
            .keyboardShortcut(",")

        Divider()

        Button("Quit Treadmill") { NSApplication.shared.terminate(nil) }
            .keyboardShortcut("q")
    }

    /// Fire-and-forget: detached task so menu dismissal doesn't cancel it
    private func fireCommand(_ action: @escaping @Sendable () async -> Void) {
        Task.detached {
            await action()
        }
    }

    private var statusLine: String {
        let t = appState.treadmill
        if t.isConnected {
            return "\(t.deviceName) — \(t.isRunning ? String(format: "%.1f km/h", t.speed) : "Idle")"
        }
        return "Treadmill"
    }

    private func formatDistance(_ meters: Double) -> String {
        meters >= 1000 ? String(format: "%.2f km", meters / 1000) : "\(Int(meters)) m"
    }

    private func formatTime(_ seconds: TimeInterval) -> String {
        let mins = Int(seconds) / 60
        let secs = Int(seconds) % 60
        return String(format: "%d:%02d", mins, secs)
    }
}
