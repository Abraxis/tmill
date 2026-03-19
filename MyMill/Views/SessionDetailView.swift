// Views/SessionDetailView.swift
import SwiftUI
import Charts

struct SessionDetailView: View {
    @ObservedObject var session: WorkoutSession

    @Environment(\.managedObjectContext) private var viewContext
    @State private var isUploading = false
    @State private var uploadResult: UploadResult?
    @State private var isFetchingHR = false

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

                // Fetch HR from HealthKit
                if session.heartRateSamples == nil {
                    fetchHeartRateButton
                }

                // Strava section
                stravaSection
            }
            .padding()
        }
    }

    private var summaryGrid: some View {
        LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 6), count: 4), spacing: 6) {
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
        VStack(alignment: .leading) {
            Text("Speed Over Time")
                .font(.headline)
            Chart(session.samples, id: \.time) { sample in
                LineMark(
                    x: .value("Time", sample.time / 60),
                    y: .value("Speed", sample.speed)
                )
                .foregroundStyle(.green)
            }
            .chartXAxisLabel("Minutes")
            .chartYAxisLabel("km/h")
            .frame(height: 200)
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
            .chartXAxisLabel("Minutes")
            .chartYAxisLabel("BPM")
            .frame(height: 150)
        }
    }

    private var fetchHeartRateButton: some View {
        Button {
            isFetchingHR = true
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
    }

    private var stravaSection: some View {
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

            if let result = uploadResult {
                switch result {
                case .success:
                    Label("Uploaded", systemImage: "checkmark.circle.fill")
                        .foregroundStyle(.green)
                        .font(.caption)
                case .failure(let msg):
                    Label(msg, systemImage: "xmark.circle.fill")
                        .foregroundStyle(.red)
                        .font(.caption)
                        .lineLimit(1)
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
