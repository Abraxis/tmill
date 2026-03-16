import SwiftUI

struct SettingsView: View {
    @Bindable var settings = SettingsManager.shared

    var body: some View {
        Form {
            Section {
                Toggle("Launch at login", isOn: $settings.launchAtLogin)
            } header: {
                Label("General", systemImage: "gearshape")
            }

            Section {
                Stepper(
                    "Minimum duration: \(Int(settings.minSessionDuration / 60)) min",
                    value: Binding(
                        get: { settings.minSessionDuration / 60 },
                        set: { settings.minSessionDuration = $0 * 60 }
                    ),
                    in: 1...60,
                    step: 1
                )
                Text("Sessions shorter than this are not saved to history.")
                    .font(.caption)
                    .foregroundStyle(.tertiary)
            } header: {
                Label("Session Tracking", systemImage: "clock")
            }

            Section {
                Stepper(
                    "Speed step: \(String(format: "%.1f", settings.speedIncrement)) km/h",
                    value: $settings.speedIncrement,
                    in: 0.1...2.0,
                    step: 0.1
                )
                Stepper(
                    "Incline step: \(String(format: "%.0f", settings.inclineIncrement))%",
                    value: $settings.inclineIncrement,
                    in: 1...5,
                    step: 1
                )
            } header: {
                Label("Controls", systemImage: "slider.horizontal.3")
            }

            Section {
                HStack {
                    Text("Speed range")
                    Spacer()
                    Text("\(String(format: "%.1f", FTMSProtocol.speedMin)) – \(String(format: "%.1f", FTMSProtocol.speedMax)) km/h")
                        .foregroundStyle(.secondary)
                }
                HStack {
                    Text("Incline range")
                    Spacer()
                    Text("\(String(format: "%.0f", FTMSProtocol.inclineMin)) – \(String(format: "%.0f", FTMSProtocol.inclineMax))%")
                        .foregroundStyle(.secondary)
                }
            } header: {
                Label("Treadmill Limits", systemImage: "info.circle")
            }
        }
        .formStyle(.grouped)
        .frame(width: 420)
        .navigationTitle("Settings")
    }
}
