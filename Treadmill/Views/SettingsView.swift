// ~/src/tmill/Treadmill/Views/SettingsView.swift
import SwiftUI

struct SettingsView: View {
    @Bindable var settings = SettingsManager.shared

    var body: some View {
        Form {
            Section("General") {
                Toggle("Launch at login", isOn: $settings.launchAtLogin)
            }

            Section("Session Tracking") {
                HStack {
                    Text("Minimum session duration")
                    Spacer()
                    TextField("Minutes", value: Binding(
                        get: { settings.minSessionDuration / 60 },
                        set: { settings.minSessionDuration = $0 * 60 }
                    ), format: .number)
                    .textFieldStyle(.roundedBorder)
                    .frame(width: 60)
                    Text("minutes")
                        .foregroundStyle(.secondary)
                }
            }

            Section("Controls") {
                HStack {
                    Text("Speed increment")
                    Spacer()
                    TextField("km/h", value: $settings.speedIncrement, format: .number)
                        .textFieldStyle(.roundedBorder)
                        .frame(width: 60)
                    Text("km/h")
                        .foregroundStyle(.secondary)
                }

                HStack {
                    Text("Incline increment")
                    Spacer()
                    TextField("%", value: $settings.inclineIncrement, format: .number)
                        .textFieldStyle(.roundedBorder)
                        .frame(width: 60)
                    Text("%")
                        .foregroundStyle(.secondary)
                }
            }
        }
        .formStyle(.grouped)
        .frame(width: 400, height: 300)
    }
}
