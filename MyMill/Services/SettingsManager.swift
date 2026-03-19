import Foundation
import ServiceManagement
import os

struct QuickPreset: Codable, Identifiable, Equatable {
    var id = UUID()
    var name: String
    var speed: Double
    var incline: Double
}

@Observable
final class SettingsManager {
    static let shared = SettingsManager()

    var minSessionDuration: Double {
        didSet { sync(key: "minSessionDuration", value: minSessionDuration) }
    }
    var launchAtLogin: Bool {
        didSet {
            sync(key: "launchAtLogin", value: launchAtLogin)
            updateLaunchAtLogin()
        }
    }
    var speedIncrement: Double {
        didSet { sync(key: "speedIncrement", value: speedIncrement) }
    }
    var inclineIncrement: Double {
        didSet { sync(key: "inclineIncrement", value: inclineIncrement) }
    }
    var quickPresets: [QuickPreset] {
        didSet { syncPresets() }
    }

    private let cloud = NSUbiquitousKeyValueStore.default
    private let defaults = UserDefaults.standard
    private let logger = Logger(subsystem: "com.mymill.app", category: "Settings")
    private var isMerging = false

    private init() {
        let d = defaults
        var msd = d.double(forKey: "minSessionDuration")
        if msd == 0 { msd = 300 }
        var si = d.double(forKey: "speedIncrement")
        if si == 0 { si = 0.5 }
        var ii = d.double(forKey: "inclineIncrement")
        if ii == 0 { ii = 1.0 }

        self.minSessionDuration = msd
        self.launchAtLogin = d.bool(forKey: "launchAtLogin")
        self.speedIncrement = si
        self.inclineIncrement = ii

        // Load quick presets
        if let data = d.data(forKey: "quickPresets"),
           let presets = try? JSONDecoder().decode([QuickPreset].self, from: data) {
            self.quickPresets = presets
        } else {
            // Default presets
            self.quickPresets = [
                QuickPreset(name: "Walk", speed: 3.0, incline: 0),
                QuickPreset(name: "Brisk", speed: 5.0, incline: 2),
                QuickPreset(name: "Hill", speed: 3.0, incline: 12),
            ]
        }

        mergeFromCloud()

        NotificationCenter.default.addObserver(
            forName: NSUbiquitousKeyValueStore.didChangeExternallyNotification,
            object: cloud, queue: .main
        ) { [weak self] _ in
            self?.mergeFromCloud()
        }
        cloud.synchronize()
    }

    private func mergeFromCloud() {
        isMerging = true
        defer { isMerging = false }
        if cloud.object(forKey: "minSessionDuration") != nil {
            minSessionDuration = cloud.double(forKey: "minSessionDuration")
        }
        if cloud.object(forKey: "launchAtLogin") != nil {
            launchAtLogin = cloud.bool(forKey: "launchAtLogin")
        }
        if cloud.object(forKey: "speedIncrement") != nil {
            speedIncrement = cloud.double(forKey: "speedIncrement")
        }
        if cloud.object(forKey: "inclineIncrement") != nil {
            inclineIncrement = cloud.double(forKey: "inclineIncrement")
        }
        if let data = cloud.data(forKey: "quickPresets"),
           let presets = try? JSONDecoder().decode([QuickPreset].self, from: data) {
            quickPresets = presets
        }
    }

    private func sync(key: String, value: Any) {
        guard !isMerging else { return }
        defaults.set(value, forKey: key)
        cloud.set(value, forKey: key)
    }

    private func syncPresets() {
        guard !isMerging else { return }
        if let data = try? JSONEncoder().encode(quickPresets) {
            defaults.set(data, forKey: "quickPresets")
            cloud.set(data, forKey: "quickPresets")
        }
    }

    private func updateLaunchAtLogin() {
        do {
            if launchAtLogin {
                try SMAppService.mainApp.register()
            } else {
                try SMAppService.mainApp.unregister()
            }
        } catch {
            logger.error("Launch at login failed: \(error.localizedDescription)")
        }
    }
}
