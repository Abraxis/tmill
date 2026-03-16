import SwiftUI

struct SettingsView: View {
    @Bindable var settings = SettingsManager.shared
    @State private var selectedTab = 0

    var body: some View {
        TabView(selection: $selectedTab) {
            generalTab
                .tabItem { Label("General", systemImage: "gearshape") }
                .tag(0)

            presetsTab
                .tabItem { Label("Quick Presets", systemImage: "star") }
                .tag(1)
        }
        .frame(width: 450, height: 420)
        .navigationTitle("Settings")
    }

    // MARK: - General Tab

    private var generalTab: some View {
        Form {
            Section("Startup") {
                Toggle("Launch at login", isOn: $settings.launchAtLogin)
            }

            Section("Session Tracking") {
                Stepper(
                    "Minimum duration: \(Int(settings.minSessionDuration / 60)) min",
                    value: Binding(
                        get: { settings.minSessionDuration / 60 },
                        set: { settings.minSessionDuration = $0 * 60 }
                    ),
                    in: 1...60,
                    step: 1
                )
            }

            Section("Controls") {
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
            }

            Section("Treadmill Limits") {
                LabeledContent("Speed range") {
                    Text("\(String(format: "%.1f", FTMSProtocol.speedMin)) – \(String(format: "%.1f", FTMSProtocol.speedMax)) km/h")
                        .foregroundStyle(.secondary)
                }
                LabeledContent("Incline range") {
                    Text("\(String(format: "%.0f", FTMSProtocol.inclineMin)) – \(String(format: "%.0f", FTMSProtocol.inclineMax))%")
                        .foregroundStyle(.secondary)
                }
            }
        }
        .formStyle(.grouped)
    }

    // MARK: - Presets Tab

    private var presetsTab: some View {
        VStack(spacing: 0) {
            // Header row
            HStack(spacing: 0) {
                Text("Name")
                    .frame(width: 120, alignment: .leading)
                Text("Speed")
                    .frame(width: 100, alignment: .center)
                Text("Incline")
                    .frame(width: 100, alignment: .center)
                Spacer()
            }
            .font(.caption.bold())
            .foregroundStyle(.secondary)
            .padding(.horizontal, 16)
            .padding(.top, 8)
            .padding(.bottom, 4)

            Divider()

            // Preset rows
            ScrollView {
                VStack(spacing: 0) {
                    ForEach($settings.quickPresets) { $preset in
                        HStack(spacing: 0) {
                            TextField("Name", text: $preset.name)
                                .textFieldStyle(.roundedBorder)
                                .frame(width: 120)

                            HStack(spacing: 4) {
                                TextField("", value: $preset.speed, format: .number.precision(.fractionLength(1)))
                                    .textFieldStyle(.roundedBorder)
                                    .frame(width: 55)
                                Text("km/h")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                            .frame(width: 100)

                            HStack(spacing: 4) {
                                TextField("", value: $preset.incline, format: .number.precision(.fractionLength(0)))
                                    .textFieldStyle(.roundedBorder)
                                    .frame(width: 45)
                                Text("%")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                            .frame(width: 100)

                            Spacer()

                            Button(role: .destructive) {
                                withAnimation {
                                    settings.quickPresets.removeAll { $0.id == preset.id }
                                }
                            } label: {
                                Image(systemName: "trash")
                                    .foregroundStyle(.red.opacity(0.7))
                            }
                            .buttonStyle(.plain)
                        }
                        .padding(.horizontal, 16)
                        .padding(.vertical, 6)

                        Divider().padding(.horizontal, 16)
                    }
                }
            }

            Divider()

            HStack {
                Button {
                    settings.quickPresets.append(
                        QuickPreset(name: "Preset", speed: 3.0, incline: 0)
                    )
                } label: {
                    Label("Add Preset", systemImage: "plus")
                }
                .buttonStyle(.bordered)

                Spacer()

                Text("Shown in menu bar for quick changes.")
                    .font(.caption)
                    .foregroundStyle(.tertiary)
            }
            .padding(10)
        }
    }
}
