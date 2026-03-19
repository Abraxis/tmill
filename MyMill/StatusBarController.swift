import AppKit

/// Wraps a closure as an NSMenu target-action pair
final class MenuAction: NSObject {
    private let handler: () -> Void
    init(_ handler: @escaping () -> Void) { self.handler = handler }
    @objc func execute() { handler() }
}

/// Owns the NSStatusItem and NSMenu, updates items in-place
final class StatusBarController: NSObject, NSMenuDelegate {
    private let statusItem: NSStatusItem
    private let menu = NSMenu()
    private unowned let appState: AppState
    private var actions: [MenuAction] = []
    private var presetActions: [MenuAction] = []

    // MARK: - Menu items (held for in-place updates)

    private let statusLine = NSMenuItem()
    private let statsSeparator = NSMenuItem.separator()

    private let speedItem = NSMenuItem()
    private let inclineItem = NSMenuItem()
    private let distanceItem = NSMenuItem()
    private let timeItem = NSMenuItem()
    private let caloriesItem = NSMenuItem()
    private let elevationItem = NSMenuItem()

    private let controlsSeparator = NSMenuItem.separator()
    private let startItem = NSMenuItem()
    private let stopItem = NSMenuItem()
    private let pauseItem = NSMenuItem()

    private let adjustSeparator = NSMenuItem.separator()
    private let speedUpItem = NSMenuItem()
    private let speedDownItem = NSMenuItem()
    private let inclineUpItem = NSMenuItem()
    private let inclineDownItem = NSMenuItem()

    private let presetSeparator = NSMenuItem.separator()

    private let programSeparator = NSMenuItem.separator()
    private let programItem = NSMenuItem()

    private let connectionSeparator = NSMenuItem.separator()
    private let connectionStatusItem = NSMenuItem()
    private let hintItem = NSMenuItem()
    private let btSettingsItem = NSMenuItem()

    private let errorSeparator = NSMenuItem.separator()
    private let errorItem = NSMenuItem()

    // Tracks where preset items are inserted
    private var presetInsertIndex: Int = 0
    private var presetCount: Int = 0

    init(appState: AppState) {
        self.appState = appState
        self.statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)

        super.init()

        if let button = statusItem.button {
            button.image = NSImage(systemSymbolName: "figure.walk", accessibilityDescription: "MyMill")
            button.imagePosition = .imageLeading
            button.title = "MyMill"
        }

        menu.delegate = self
        buildMenu()
        statusItem.menu = menu
    }

    // MARK: - Build menu (once)

    private func buildMenu() {
        let mgr = appState.manager
        let settings = appState.settings

        // Status line
        statusLine.isEnabled = false
        menu.addItem(statusLine)
        menu.addItem(statsSeparator)

        // Stats (disabled = non-interactive text)
        for item in [speedItem, inclineItem, distanceItem, timeItem, caloriesItem, elevationItem] {
            item.isEnabled = false
            menu.addItem(item)
        }

        // Controls
        menu.addItem(controlsSeparator)
        startItem.title = "▶ Start"
        wireAction(startItem) { Task { await mgr.start() } }
        menu.addItem(startItem)

        stopItem.title = "⏹ Stop"
        wireAction(stopItem) { Task { await mgr.stop() } }
        menu.addItem(stopItem)

        pauseItem.title = "⏸ Pause"
        wireAction(pauseItem) { Task { await mgr.pause() } }
        menu.addItem(pauseItem)

        // Adjustments
        menu.addItem(adjustSeparator)

        speedUpItem.title = "Speed + (\(String(format: "%.1f", settings.speedIncrement)))"
        wireAction(speedUpItem) { [weak self] in
            guard let s = self?.appState else { return }
            Task { await s.manager.setSpeed(s.mymill.targetSpeed + s.settings.speedIncrement) }
        }
        menu.addItem(speedUpItem)

        speedDownItem.title = "Speed − (\(String(format: "%.1f", settings.speedIncrement)))"
        wireAction(speedDownItem) { [weak self] in
            guard let s = self?.appState else { return }
            Task { await s.manager.setSpeed(s.mymill.targetSpeed - s.settings.speedIncrement) }
        }
        menu.addItem(speedDownItem)

        inclineUpItem.title = "Incline + (\(String(format: "%.0f", settings.inclineIncrement))%)"
        wireAction(inclineUpItem) { [weak self] in
            guard let s = self?.appState else { return }
            Task { await s.manager.setIncline(s.mymill.targetIncline + s.settings.inclineIncrement) }
        }
        menu.addItem(inclineUpItem)

        inclineDownItem.title = "Incline − (\(String(format: "%.0f", settings.inclineIncrement))%)"
        wireAction(inclineDownItem) { [weak self] in
            guard let s = self?.appState else { return }
            Task { await s.manager.setIncline(s.mymill.targetIncline - s.settings.inclineIncrement) }
        }
        menu.addItem(inclineDownItem)

        // Presets placeholder
        menu.addItem(presetSeparator)
        presetInsertIndex = menu.items.count

        // Program
        menu.addItem(programSeparator)
        programItem.isEnabled = false
        menu.addItem(programItem)

        // Connection status (shown when disconnected)
        menu.addItem(connectionSeparator)
        connectionStatusItem.isEnabled = false
        menu.addItem(connectionStatusItem)

        hintItem.isEnabled = false
        menu.addItem(hintItem)

        btSettingsItem.title = "Open System Settings"
        wireAction(btSettingsItem) {
            if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Bluetooth") {
                NSWorkspace.shared.open(url)
            }
        }
        menu.addItem(btSettingsItem)

        // Error
        menu.addItem(errorSeparator)
        errorItem.isEnabled = false
        menu.addItem(errorItem)

        // Navigation
        menu.addItem(NSMenuItem.separator())

        let historyItem = NSMenuItem()
        historyItem.title = "Open History..."
        historyItem.keyEquivalent = "h"
        historyItem.keyEquivalentModifierMask = .command
        wireAction(historyItem) { [weak self] in self?.activateAndOpen("Workout History") }
        menu.addItem(historyItem)

        let programsItem = NSMenuItem()
        programsItem.title = "Edit Programs..."
        wireAction(programsItem) { [weak self] in self?.activateAndOpen("Edit Programs") }
        menu.addItem(programsItem)

        let settingsItem = NSMenuItem()
        settingsItem.title = "Settings..."
        settingsItem.keyEquivalent = ","
        settingsItem.keyEquivalentModifierMask = .command
        wireAction(settingsItem) { [weak self] in self?.activateAndOpen("Settings") }
        menu.addItem(settingsItem)

        menu.addItem(NSMenuItem.separator())

        let quitItem = NSMenuItem()
        quitItem.title = "Quit MyMill"
        quitItem.keyEquivalent = "q"
        quitItem.keyEquivalentModifierMask = .command
        wireAction(quitItem) { NSApplication.shared.terminate(nil) }
        menu.addItem(quitItem)
    }

    // MARK: - Update (called by 2s timer + menuNeedsUpdate)

    func update() {
        let t = appState.mymill
        guard let engine = appState.programEngine else { return }
        let connected = t.isConnected
        let running = t.isRunning

        // Status bar button
        if let button = statusItem.button {
            button.title = connected && t.speed > 0
                ? String(format: " %.1f", t.speed)
                : " MyMill"
        }

        // Status line
        if connected {
            let name = t.deviceName.isEmpty ? "MyMill" : t.deviceName
            statusLine.title = running
                ? "\(name) — \(String(format: "%.1f km/h", t.speed))"
                : "\(name) — Idle"
        } else {
            statusLine.title = "MyMill"
        }

        // Stats
        speedItem.title = "Speed: \(String(format: "%.1f", t.speed)) km/h"
        inclineItem.title = "Incline: \(String(format: "%.0f", t.incline))%"
        distanceItem.title = "Distance: \(formatDistance(t.distance))"
        timeItem.title = "Time: \(formatTime(t.elapsed))"
        caloriesItem.title = "Calories: \(t.calories) kcal"
        elevationItem.title = "Elevation: \(Int(t.elevationGain)) m"

        // Stats visibility
        for item in [speedItem, inclineItem, distanceItem, timeItem, caloriesItem, elevationItem,
                     statsSeparator, controlsSeparator, adjustSeparator] {
            item.isHidden = !connected
        }

        // Controls
        startItem.isHidden = !connected || running
        stopItem.isHidden = !connected || !running
        pauseItem.isHidden = !connected || !running

        // Adjustments
        for item in [speedUpItem, speedDownItem, inclineUpItem, inclineDownItem] {
            item.isHidden = !connected
        }

        // Program
        if engine.isActive, let name = engine.programName {
            programItem.title = "Program: \(name) — \(engine.currentSegmentIndex + 1)/\(engine.totalSegments) (\(Int(engine.segmentProgress * 100))%)"
            programItem.isHidden = false
            programSeparator.isHidden = false
        } else {
            programItem.isHidden = true
            programSeparator.isHidden = true
        }

        // Connection (shown when disconnected)
        connectionStatusItem.title = t.connectionStatus.rawValue
        connectionStatusItem.isHidden = connected
        connectionSeparator.isHidden = connected

        let showHint = !connected && (t.connectionStatus == .disconnected || t.connectionStatus == .scanning)
        hintItem.title = "Turn on treadmill to connect"
        hintItem.isHidden = !showHint

        btSettingsItem.isHidden = t.connectionStatus != .unauthorized

        // Error
        if let error = t.consumeLastError() {
            errorItem.title = "⚠ \(error)"
            errorItem.isHidden = false
            errorSeparator.isHidden = false
        } else {
            errorItem.isHidden = true
            errorSeparator.isHidden = true
        }

        // Presets
        presetSeparator.isHidden = !connected || appState.settings.quickPresets.isEmpty
    }

    // MARK: - NSMenuDelegate

    func menuNeedsUpdate(_ menu: NSMenu) {
        rebuildPresets()
        update()
    }

    // MARK: - Presets

    private func rebuildPresets() {
        // Remove old preset items and their actions
        for _ in 0..<presetCount {
            menu.removeItem(at: presetInsertIndex)
        }
        presetCount = 0
        presetActions.removeAll()

        let presets = appState.settings.quickPresets
        let mgr = appState.manager
        for preset in presets {
            let item = NSMenuItem()
            item.title = "⚡ \(preset.name) — \(String(format: "%.1f", preset.speed)) km/h, \(String(format: "%.0f", preset.incline))%"
            let action = MenuAction {
                Task {
                    await mgr.setSpeed(preset.speed)
                    await mgr.setIncline(preset.incline)
                }
            }
            presetActions.append(action)
            item.target = action
            item.action = #selector(MenuAction.execute)
            menu.insertItem(item, at: presetInsertIndex + presetCount)
            presetCount += 1
        }
    }

    // MARK: - Helpers

    private func wireAction(_ item: NSMenuItem, _ handler: @escaping () -> Void) {
        let action = MenuAction(handler)
        actions.append(action)
        item.target = action
        item.action = #selector(MenuAction.execute)
    }

    private func activateAndOpen(_ windowTitle: String) {
        NSApplication.shared.activate(ignoringOtherApps: true)
        if let w = NSApp.windows.first(where: { $0.title == windowTitle }) {
            w.makeKeyAndOrderFront(nil)
        }
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
