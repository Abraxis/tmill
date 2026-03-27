// Views/SessionDetailView.swift
import SwiftUI
import Charts
import UniformTypeIdentifiers

struct SessionDetailView: View {
    @ObservedObject var session: WorkoutSession

    @Environment(\.managedObjectContext) private var viewContext
    @State private var isUploading = false
    @State private var uploadResult: UploadResult?
    @State private var isFetchingHR = false
    @State private var fetchHRResult: String?
    @State private var importResult: String?
    @State private var isDropTargeted = false

    private enum UploadResult {
        case success
        case failure(String)
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 12) {
                // Summary stats
                summaryGrid

                // Speed over time chart
                if !session.samples.isEmpty {
                    speedChart
                    inclineChart
                }

                // Heart rate chart
                if !session.hrSamples.isEmpty {
                    heartRateChart
                }

                // Fetch HR from HealthKit or show export guidance
                if session.heartRateSamples == nil {
                    if HealthKitManager.shared.isAvailable {
                        fetchHeartRateButton
                    } else {
                        healthKitUnavailableHint
                    }
                }

                // Strava section
                stravaSection
            }
            .padding()
        }
        .onDrop(of: [.fileURL], isTargeted: $isDropTargeted) { providers in
            handleDrop(providers)
        }
        .overlay {
            if isDropTargeted {
                RoundedRectangle(cornerRadius: 8)
                    .stroke(.blue, lineWidth: 2)
                    .background(.blue.opacity(0.1))
                    .clipShape(RoundedRectangle(cornerRadius: 8))
            }
        }
    }

    private var hasHeartRate: Bool {
        session.avgHeartRate > 0
    }

    private var summaryGrid: some View {
        let columns = hasHeartRate ? 5 : 4
        return LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 6), count: columns), spacing: 6) {
            StatCard(label: "Duration", value: session.durationFormatted, icon: "clock", color: .orange)
            StatCard(label: "Distance", value: String(format: "%.2f km", session.distanceKm), icon: "figure.walk", color: .green)
            StatCard(label: "Calories", value: "\(session.calories)", icon: "flame", color: .red)
            StatCard(label: "Avg Speed", value: String(format: "%.1f km/h", session.avgSpeed), icon: "speedometer", color: .blue)
            StatCard(label: "Max Speed", value: String(format: "%.1f km/h", session.maxSpeed), icon: "arrow.up", color: .cyan)
            StatCard(label: "Avg Incline", value: String(format: "%.1f%%", session.avgIncline), icon: "arrow.up.right", color: .indigo)
            StatCard(label: "Elevation", value: String(format: "%.0f m", session.computedElevationGain), icon: "mountain.2", color: .purple)
            if session.avgHeartRate > 0 {
                StatCard(label: "Avg HR", value: "\(Int(session.avgHeartRate)) bpm", icon: "heart.fill", color: .pink)
                StatCard(label: "Max HR", value: "\(Int(session.maxHeartRate)) bpm", icon: "bolt.heart.fill", color: .red)
            }
        }
    }

    private var speedChart: some View {
        let hrSamples = session.hrSamples
        let bpms = hrSamples.map(\.bpm)
        let minBPM = Double(bpms.min() ?? 60)
        let maxBPM = Double(bpms.max() ?? 180)
        let bpmRange = max(maxBPM - minBPM, 1)
        let maxSpeed = session.maxSpeed > 0 ? session.maxSpeed : 6.5
        let scaledHR: [(time: Double, value: Double)] = hrSamples.map { sample in
            let scaled = (Double(sample.bpm) - minBPM) / bpmRange * maxSpeed
            return (time: sample.time / 60, value: scaled)
        }

        return VStack(alignment: .leading) {
            HStack {
                Text("Speed Over Time")
                    .font(.headline)
                if !hrSamples.isEmpty {
                    Text("+ Heart Rate")
                        .font(.headline)
                        .foregroundStyle(.red.opacity(0.7))
                }
            }
            Chart {
                ForEach(session.samples, id: \.time) { sample in
                    LineMark(
                        x: .value("Time", sample.time / 60),
                        y: .value("Value", sample.speed),
                        series: .value("Series", "Speed")
                    )
                    .foregroundStyle(.green)
                }
                ForEach(Array(scaledHR.enumerated()), id: \.offset) { _, point in
                    LineMark(
                        x: .value("Time", point.time),
                        y: .value("Value", point.value),
                        series: .value("Series", "HR")
                    )
                    .foregroundStyle(.red.opacity(0.5))
                    .lineStyle(StrokeStyle(lineWidth: 1))
                }
            }
            .chartXScale(domain: 0...(session.duration / 60))
            .chartXAxisLabel("Minutes")
            .chartYAxisLabel("km/h")
            .frame(height: 200)
            if !hrSamples.isEmpty {
                Text("HR range: \(bpms.min() ?? 0)–\(bpms.max() ?? 0) bpm")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
        }
    }

    private var inclineChart: some View {
        VStack(alignment: .leading) {
            Text("Incline Over Time")
                .font(.headline)
            Chart(session.samples, id: \.time) { sample in
                LineMark(
                    x: .value("Time", sample.time / 60),
                    y: .value("Incline", sample.incline)
                )
                .foregroundStyle(.purple)
            }
            .chartXScale(domain: 0...(session.duration / 60))
            .chartXAxisLabel("Minutes")
            .chartYAxisLabel("%")
            .frame(height: 150)
        }
    }

    private var heartRateChart: some View {
        VStack(alignment: .leading) {
            Text("Heart Rate Over Time")
                .font(.headline)
            Chart(session.hrSamples, id: \.time) { sample in
                LineMark(
                    x: .value("Time", sample.time / 60),
                    y: .value("BPM", sample.bpm)
                )
                .foregroundStyle(.red)
            }
            .chartXScale(domain: 0...(session.duration / 60))
            .chartXAxisLabel("Minutes")
            .chartYAxisLabel("BPM")
            .frame(height: 150)
        }
    }

    private var fetchHeartRateButton: some View {
        VStack(alignment: .leading, spacing: 6) {
            Button {
                isFetchingHR = true
                fetchHRResult = nil
                Task { @MainActor in
                    let endDate = session.date.addingTimeInterval(session.duration)
                    let hrRaw = await HealthKitManager.shared.fetchHeartRateSamples(from: session.date, to: endDate)
                    let hrSamples = hrRaw.map {
                        WorkoutSession.HeartRateSample(time: $0.date.timeIntervalSince(session.date), bpm: $0.bpm)
                    }
                    if !hrSamples.isEmpty {
                        let bpms = hrSamples.map(\.bpm)
                        session.avgHeartRate = Double(bpms.reduce(0, +)) / Double(bpms.count)
                        session.maxHeartRate = Double(bpms.max() ?? 0)
                        session.heartRateSamples = try? JSONEncoder().encode(hrSamples)
                        try? viewContext.save()
                        fetchHRResult = "Found \(hrSamples.count) heart rate samples"
                    } else {
                        fetchHRResult = "No heart rate data found for this session"
                    }
                    isFetchingHR = false
                }
            } label: {
                HStack(spacing: 6) {
                    if isFetchingHR {
                        ProgressView().controlSize(.small)
                    } else {
                        Image(systemName: "heart.text.clipboard")
                    }
                    Text("Fetch Heart Rate from HealthKit")
                }
            }
            .disabled(isFetchingHR)

            if let result = fetchHRResult {
                Label(result, systemImage: result.hasPrefix("Found") ? "checkmark.circle.fill" : "info.circle.fill")
                    .foregroundStyle(result.hasPrefix("Found") ? .green : .secondary)
                    .font(.caption)
            }
        }
    }

    private var healthKitUnavailableHint: some View {
        VStack(alignment: .leading, spacing: 6) {
            Label("HealthKit is not available on this Mac", systemImage: "heart.slash")
                .font(.callout)
                .foregroundStyle(.secondary)
            Text("To add heart rate data, export from your iPhone:")
                .font(.caption)
                .foregroundStyle(.secondary)
            VStack(alignment: .leading, spacing: 3) {
                Text("1. Open **Health** → tap your **profile picture** (top right)")
                Text("2. Tap **Export All Health Data** → **Export**")
                Text("3. AirDrop the file to this Mac")
                Text("4. Drop the **.zip** or **export.xml** onto this window")
            }
            .font(.caption)
            .foregroundStyle(.secondary)

            if let result = importResult {
                Label(result, systemImage: result.hasPrefix("Imported") ? "checkmark.circle.fill" : "xmark.circle.fill")
                    .foregroundStyle(result.hasPrefix("Imported") ? .green : .red)
                    .font(.caption)
            }
        }
        .padding(8)
        .background(.quaternary.opacity(0.5))
        .clipShape(RoundedRectangle(cornerRadius: 6))
    }

    // MARK: - Health Export XML Import

    private func handleDrop(_ providers: [NSItemProvider]) -> Bool {
        guard let provider = providers.first else { return false }
        provider.loadItem(forTypeIdentifier: UTType.fileURL.identifier, options: nil) { item, _ in
            guard let data = item as? Data,
                  let url = URL(dataRepresentation: data, relativeTo: nil) else {
                Task { @MainActor in self.importResult = "Could not read dropped file" }
                return
            }
            // Parse on background thread — export.xml can be multi-GB
            let ext = url.pathExtension.lowercased()
            guard ext == "xml" || ext == "zip" else {
                Task { @MainActor in self.importResult = "Drop an export.xml or .zip file" }
                return
            }
            Task { @MainActor in self.importResult = "Parsing health export..." }
            let sessionStart = self.session.date
            let sessionEnd = self.session.date.addingTimeInterval(self.session.duration)
            Task.detached(priority: .userInitiated) {
                guard let parser = HealthExportParser(url: url, from: sessionStart, to: sessionEnd) else {
                    await MainActor.run { self.importResult = "Could not open file" }
                    return
                }
                let hrSamples = parser.parse()
                await MainActor.run {
                    self.applyHeartRateSamples(hrSamples)
                }
            }
        }
        return true
    }

    private func applyHeartRateSamples(_ hrSamples: [WorkoutSession.HeartRateSample]) {
        if hrSamples.isEmpty {
            importResult = "No heart rate data found for this session's time window"
            return
        }

        let bpms = hrSamples.map(\.bpm)
        session.avgHeartRate = Double(bpms.reduce(0, +)) / Double(bpms.count)
        session.maxHeartRate = Double(bpms.max() ?? 0)
        session.heartRateSamples = try? JSONEncoder().encode(hrSamples)
        try? viewContext.save()
        importResult = "Imported \(hrSamples.count) heart rate samples"
    }

    private var stravaSection: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                if let activityId = session.stravaActivityId {
                    Button {
                        if let url = URL(string: "https://www.strava.com/activities/\(activityId)") {
                            NSWorkspace.shared.open(url)
                        }
                    } label: {
                        HStack(spacing: 6) {
                            Image(systemName: "link")
                            Text("View on Strava")
                        }
                    }
                }

                if StravaManager.shared.isConnected && !session.samples.isEmpty {
                    Button {
                        isUploading = true
                        uploadResult = nil
                        Task { @MainActor in
                            do {
                                let activityId = try await StravaManager.shared.reuploadSession(session)
                                if let activityId {
                                    session.stravaActivityId = String(activityId)
                                    try? viewContext.save()
                                }
                                uploadResult = .success
                            } catch {
                                uploadResult = .failure(error.localizedDescription)
                            }
                            isUploading = false
                        }
                    } label: {
                        HStack(spacing: 6) {
                            if isUploading {
                                ProgressView().controlSize(.small)
                            } else {
                                Image(systemName: "arrow.up.to.line")
                            }
                            Text(session.stravaActivityId != nil ? "Re-upload to Strava" : "Upload to Strava")
                        }
                    }
                    .disabled(isUploading)
                }
            }

            if let result = uploadResult {
                switch result {
                case .success:
                    Label("Uploaded successfully", systemImage: "checkmark.circle.fill")
                        .foregroundStyle(.green)
                        .font(.caption)
                case .failure(let msg):
                    Label(msg, systemImage: "xmark.circle.fill")
                        .foregroundStyle(.red)
                        .font(.caption)
                        .textSelection(.enabled)
                }
            }
        }
    }
}

private struct StatCard: View {
    let label: String
    let value: String
    let icon: String
    let color: Color

    var body: some View {
        HStack(spacing: 4) {
            Image(systemName: icon)
                .font(.caption)
                .foregroundStyle(color)
                .frame(width: 14)
            VStack(alignment: .leading, spacing: 0) {
                Text(value)
                    .font(.caption.bold())
                Text(label)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.vertical, 3)
        .padding(.horizontal, 6)
        .background(color.opacity(0.08))
        .clipShape(RoundedRectangle(cornerRadius: 5))
    }
}
