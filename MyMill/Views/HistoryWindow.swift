// Views/HistoryWindow.swift
import SwiftUI
import CoreData

struct HistoryWindow: View {
    @Environment(\.managedObjectContext) private var viewContext
    @State private var selectedTab = 0
    @State private var selectedSession: WorkoutSession?

    @FetchRequest(
        sortDescriptors: [NSSortDescriptor(keyPath: \WorkoutSession.date, ascending: false)],
        animation: .default
    )
    private var sessions: FetchedResults<WorkoutSession>

    var body: some View {
        TabView(selection: $selectedTab) {
            sessionsTab
                .tabItem { Label("Sessions", systemImage: "list.bullet") }
                .tag(0)

            TrendsView()
                .tabItem { Label("Trends", systemImage: "chart.xyaxis.line") }
                .tag(1)
        }
        .frame(minWidth: 600, minHeight: 400)
    }

    private var sessionsTab: some View {
        HSplitView {
            sessionList
                .frame(minWidth: 250)
            if let session = selectedSession {
                SessionDetailView(session: session)
                    .frame(minWidth: 350)
            } else {
                Text("Select a session")
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
    }

    private var sessionList: some View {
        List(selection: $selectedSession) {
            ForEach(sessions, id: \.objectID) { session in
                SessionRow(session: session)
                    .tag(session)
                    .onTapGesture { selectedSession = session }
            }
            .onDelete(perform: deleteSessions)
        }
    }

    private func deleteSessions(at offsets: IndexSet) {
        for index in offsets {
            viewContext.delete(sessions[index])
        }
        do {
            try viewContext.save()
        } catch {
            viewContext.rollback()
        }
    }
}

private struct SessionRow: View {
    let session: WorkoutSession

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text(session.date, style: .date)
                    .font(.headline)
                Spacer()
                if session.stravaActivityId != nil {
                    Image(systemName: "arrow.up.to.line")
                        .foregroundStyle(.orange)
                        .font(.caption)
                        .help("Uploaded to Strava")
                }
                if session.heartRateSamples != nil {
                    Image(systemName: "heart.fill")
                        .foregroundStyle(.red)
                        .font(.caption)
                        .help("Heart rate data available")
                }
            }
            HStack(spacing: 12) {
                Label(session.durationFormatted, systemImage: "clock")
                Label(String(format: "%.2f km", session.distanceKm), systemImage: "figure.walk")
                Label("\(session.calories) cal", systemImage: "flame")
            }
            .font(.caption)
            .foregroundStyle(.secondary)
        }
        .padding(.vertical, 4)
    }
}
