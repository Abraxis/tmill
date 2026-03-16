// ~/src/tmill/Treadmill/TreadmillApp.swift
import SwiftUI

@main
struct TreadmillApp: App {
    @State private var treadmillState = TreadmillState()
    @State private var manager: TreadmillManager?
    @State private var sessionTracker: SessionTracker?
    @State private var programEngine: ProgramEngine?

    private let persistence = PersistenceController.shared
    private let settings = SettingsManager.shared

    var body: some Scene {
        MenuBarExtra {
            if let manager {
                MenuBarView(
                    treadmillState: treadmillState,
                    manager: manager,
                    programEngine: programEngine,
                    onOpenHistory: { openWindow(id: "history") },
                    onOpenPrograms: { openWindow(id: "programs") },
                    onOpenSettings: { openWindow(id: "settings") },
                    onQuit: { NSApplication.shared.terminate(nil) }
                )
                .onAppear(perform: setup)
            } else {
                Text("Initializing...")
                    .onAppear(perform: setup)
            }
        } label: {
            menuBarLabel
        }
        .menuBarExtraStyle(.window)

        Window("Workout History", id: "history") {
            HistoryWindow()
                .environment(\.managedObjectContext, persistence.viewContext)
        }

        Window("Edit Programs", id: "programs") {
            ProgramEditorView()
                .environment(\.managedObjectContext, persistence.viewContext)
        }

        Window("Settings", id: "settings") {
            SettingsView()
        }
    }

    @Environment(\.openWindow) private var openWindow

    private var menuBarLabel: some View {
        HStack(spacing: 4) {
            Image(systemName: "figure.walk")
            if treadmillState.isConnected {
                Text(String(format: "%.1f", treadmillState.speed))
                    .font(.system(.caption, design: .monospaced))
            }
        }
    }

    private func setup() {
        guard manager == nil else { return }
        let mgr = TreadmillManager(state: treadmillState)
        manager = mgr
        sessionTracker = SessionTracker(
            state: treadmillState,
            persistence: persistence,
            minDuration: settings.minSessionDuration
        )
        programEngine = ProgramEngine(state: treadmillState)

        // Sleep/wake observers
        let workspace = NSWorkspace.shared
        workspace.notificationCenter.addObserver(
            forName: NSWorkspace.willSleepNotification,
            object: nil, queue: .main
        ) { _ in
            mgr.disconnect()
        }
        workspace.notificationCenter.addObserver(
            forName: NSWorkspace.didWakeNotification,
            object: nil, queue: .main
        ) { _ in
            mgr.startScanning()
        }

        // Periodic session tracking + program engine updates
        Timer.scheduledTimer(withTimeInterval: 5.0, repeats: true) { _ in
            Task { @MainActor in
                sessionTracker?.check()
                sessionTracker?.recordSample()
                programEngine?.updateFromState()

                // Send pending program commands
                if let speed = programEngine?.pendingSpeed {
                    await mgr.setSpeed(speed)
                    programEngine?.clearPendingCommands()
                }
                if let incline = programEngine?.pendingIncline {
                    await mgr.setIncline(incline)
                    programEngine?.clearPendingCommands()
                }
                if programEngine?.shouldStop == true {
                    await mgr.stop()
                    programEngine?.stop()
                }
            }
        }
    }
}
