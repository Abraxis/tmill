// ~/src/tmill/Treadmill/Services/SettingsManager.swift
import Foundation
import ServiceManagement
import os

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

    private let cloud = NSUbiquitousKeyValueStore.default
    private let defaults = UserDefaults.standard
    private let logger = Logger(subsystem: "com.treadmill.app", category: "Settings")
    private var isMerging = false

    private init() {
        // Load from local defaults first — use local vars to avoid didSet during init
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

        // Merge iCloud values (iCloud wins if present)
        mergeFromCloud()

        // Observe iCloud changes
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
    }

    private func sync(key: String, value: Any) {
        guard !isMerging else { return }
        defaults.set(value, forKey: key)
        cloud.set(value, forKey: key)
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
