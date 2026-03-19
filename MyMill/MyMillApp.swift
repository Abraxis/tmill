import SwiftUI

@main
struct MyMillApp: App {
    @State private var appState = AppState()

    var body: some Scene {
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
    let mymill = MyMillState()
    let persistence = PersistenceController.shared
    let settings = SettingsManager.shared
    let manager: MyMillManager
    var sessionTracker: SessionTracker!
    var programEngine: ProgramEngine!
    var statusBarController: StatusBarController!

    init() {
        persistence.migrateSessionSamples()
        manager = MyMillManager(state: mymill)
        programEngine = ProgramEngine(state: mymill)
        sessionTracker = SessionTracker(
            state: mymill,
            persistence: persistence,
            minDuration: settings.minSessionDuration
        )
        statusBarController = StatusBarController(appState: self)

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

        // Update menu + session tracking on a calm 2s timer
        Timer.scheduledTimer(withTimeInterval: 2.0, repeats: true) { [weak self] _ in
            guard let self else { return }
            Task { @MainActor in
                // Update menu bar
                self.statusBarController.update()

                // Session tracking
                self.sessionTracker.check()
                self.sessionTracker.recordSample()

                // Program engine
                self.programEngine.updateFromState()
                let pendingSpeed = self.programEngine.pendingSpeed
                let pendingIncline = self.programEngine.pendingIncline
                self.programEngine.clearPendingCommands()
                if let speed = pendingSpeed {
                    await self.manager.setSpeed(speed)
                }
                if let incline = pendingIncline {
                    await self.manager.setIncline(incline)
                }
                if self.programEngine.shouldStop {
                    await self.manager.stop()
                    self.programEngine.stop()
                }
            }
        }
    }
}
