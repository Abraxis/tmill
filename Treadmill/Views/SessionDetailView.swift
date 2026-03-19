// ~/src/tmill/Treadmill/Views/SessionDetailView.swift
import SwiftUI
import Charts

struct SessionDetailView: View {
    let session: WorkoutSession

    @State private var isUploading = false
    @State private var uploadResult: UploadResult?

    private enum UploadResult {
        case success
        case failure(String)
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                // Summary stats
                summaryGrid

                // Speed over time chart
                if !session.samples.isEmpty {
                    speedChart
                    inclineChart
                }

                // Re-upload to Strava
                if StravaManager.shared.isConnected && !session.samples.isEmpty {
                    stravaReuploadButton
                }
            }
            .padding()
        }
    }

    private var stravaReuploadButton: some View {
        HStack {
            Button {
                isUploading = true
                uploadResult = nil
                Task {
                    do {
                        try await StravaManager.shared.reuploadSession(session)
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
                    Text("Upload to Strava")
                }
            }
            .disabled(isUploading)

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

    private var summaryGrid: some View {
        LazyVGrid(columns: [
            GridItem(.flexible()), GridItem(.flexible()), GridItem(.flexible())
        ], spacing: 12) {
            StatCard(label: "Duration", value: session.durationFormatted, icon: "clock")
            StatCard(label: "Distance", value: String(format: "%.2f km", session.distanceKm), icon: "figure.walk")
            StatCard(label: "Calories", value: "\(session.calories)", icon: "flame")
            StatCard(label: "Avg Speed", value: String(format: "%.1f km/h", session.avgSpeed), icon: "speedometer")
            StatCard(label: "Max Speed", value: String(format: "%.1f km/h", session.maxSpeed), icon: "arrow.up")
            StatCard(label: "Avg Incline", value: String(format: "%.1f%%", session.avgIncline), icon: "arrow.up.right")
            StatCard(label: "Elevation", value: String(format: "%.0f m", session.computedElevationGain), icon: "mountain.2")
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
}

private struct StatCard: View {
    let label: String
    let value: String
    let icon: String

    var body: some View {
        VStack(spacing: 4) {
            Image(systemName: icon)
                .foregroundStyle(.secondary)
            Text(value)
                .font(.title3.bold())
            Text(label)
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity)
        .padding(12)
        .background(.quaternary)
        .clipShape(RoundedRectangle(cornerRadius: 8))
    }
}
