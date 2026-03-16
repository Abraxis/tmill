// ~/src/tmill/Treadmill/TreadmillApp.swift
import SwiftUI

@main
struct TreadmillApp: App {
    @State private var treadmillState = TreadmillState()
    @State private var manager: TreadmillManager?

    var body: some Scene {
        MenuBarExtra {
            if let manager {
                MenuBarView(
                    treadmillState: treadmillState,
                    manager: manager,
                    onOpenHistory: openHistory,
                    onOpenPrograms: openPrograms,
                    onOpenSettings: openSettings,
                    onQuit: { NSApplication.shared.terminate(nil) }
                )
            } else {
                Text("Initializing...")
                    .onAppear { manager = TreadmillManager(state: treadmillState) }
            }
        } label: {
            menuBarLabel
        }
        .menuBarExtraStyle(.window)

        Window("Workout History", id: "history") {
            HistoryWindow()
                .environment(\.managedObjectContext, PersistenceController.shared.viewContext)
        }

        Window("Edit Programs", id: "programs") {
            ProgramEditorView()
                .environment(\.managedObjectContext, PersistenceController.shared.viewContext)
        }

        Window("Settings", id: "settings") {
            Text("Settings — Coming Soon")
                .frame(width: 400, height: 300)
        }
    }

    private var menuBarLabel: some View {
        HStack(spacing: 4) {
            Image(systemName: "figure.walk")
            if treadmillState.isConnected {
                Text(String(format: "%.1f", treadmillState.speed))
                    .font(.system(.caption, design: .monospaced))
            }
        }
    }

    @Environment(\.openWindow) private var openWindow

    private func openHistory() {
        openWindow(id: "history")
    }

    private func openPrograms() {
        openWindow(id: "programs")
    }

    private func openSettings() {
        openWindow(id: "settings")
    }
}
