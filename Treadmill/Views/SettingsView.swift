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
                ForEach($settings.quickPresets) { $preset in
                    HStack(spacing: 8) {
                        TextField("Name", text: $preset.name)
                            .frame(width: 80)
                        Spacer()
                        Text("Speed:")
                            .foregroundStyle(.secondary)
                            .font(.caption)
                        TextField("", value: $preset.speed, format: .number.precision(.fractionLength(1)))
                            .textFieldStyle(.roundedBorder)
                            .frame(width: 50)
                        Text("km/h")
                            .foregroundStyle(.secondary)
                            .font(.caption)
                        Text("Incline:")
                            .foregroundStyle(.secondary)
                            .font(.caption)
                        TextField("", value: $preset.incline, format: .number.precision(.fractionLength(0)))
                            .textFieldStyle(.roundedBorder)
                            .frame(width: 40)
                        Text("%")
                            .foregroundStyle(.secondary)
                            .font(.caption)
                    }
                }
                .onDelete { indices in
                    settings.quickPresets.remove(atOffsets: indices)
                }
                Button("Add Preset") {
                    settings.quickPresets.append(
                        QuickPreset(name: "Preset", speed: 3.0, incline: 0)
                    )
                }
            } header: {
                Label("Quick Presets", systemImage: "star")
            } footer: {
                Text("Quick presets appear in the menu bar dropdown for one-tap speed/incline changes.")
                    .font(.caption)
                    .foregroundStyle(.tertiary)
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
        .frame(width: 480, height: 620)
        .navigationTitle("Settings")
    }
}
