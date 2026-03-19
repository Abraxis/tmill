// ~/src/tmill/Treadmill/Views/TrendsView.swift
import SwiftUI
import Charts
import CoreData

struct TrendsView: View {
    @Environment(\.managedObjectContext) private var viewContext

    @FetchRequest(
        sortDescriptors: [NSSortDescriptor(keyPath: \WorkoutSession.date, ascending: true)],
        animation: .default
    )
    private var sessions: FetchedResults<WorkoutSession>

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                // All-time stats
                allTimeStats

                if !weeklyData.isEmpty {
                    weeklyDistanceChart
                    weeklyCaloriesChart
                    avgSpeedTrendChart
                }
            }
            .padding()
        }
    }

    // MARK: - All-time Stats

    private var allTimeStats: some View {
        HStack(spacing: 16) {
            TrendStatCard(label: "Total Sessions", value: "\(sessions.count)")
            TrendStatCard(label: "Total Distance", value: String(format: "%.1f km", totalDistance))
            TrendStatCard(label: "Total Time", value: formatTotalTime)
            TrendStatCard(label: "Total Calories", value: "\(totalCalories)")
            TrendStatCard(label: "Total Elevation", value: String(format: "%.0f m", totalElevation))
        }
    }

    private var totalDistance: Double {
        sessions.reduce(0) { $0 + $1.distance } / 1000
    }

    private var totalCalories: Int {
        sessions.reduce(0) { $0 + Int($1.calories) }
    }

    private var totalElevation: Double {
        sessions.reduce(0) { $0 + $1.computedElevationGain }
    }

    private var formatTotalTime: String {
        let total = sessions.reduce(0.0) { $0 + $1.duration }
        let hours = Int(total) / 3600
        let mins = (Int(total) % 3600) / 60
        return "\(hours)h \(mins)m"
    }

    // MARK: - Weekly Aggregations

    private struct WeekData: Identifiable {
        let id: Date  // start of week
        var distance: Double = 0
        var calories: Int = 0
        var avgSpeed: Double = 0
        var sessionCount: Int = 0
    }

    private var weeklyData: [WeekData] {
        let calendar = Calendar.current
        var weeks: [Date: WeekData] = [:]

        for session in sessions {
            let weekStart = calendar.dateInterval(of: .weekOfYear, for: session.date)?.start ?? session.date
            var week = weeks[weekStart] ?? WeekData(id: weekStart)
            week.distance += session.distance / 1000
            week.calories += Int(session.calories)
            week.avgSpeed += session.avgSpeed
            week.sessionCount += 1
            weeks[weekStart] = week
        }

        return weeks.values
            .map { var w = $0; w.avgSpeed = w.sessionCount > 0 ? w.avgSpeed / Double(w.sessionCount) : 0; return w }
            .sorted { $0.id < $1.id }
    }

    // MARK: - Charts

    private var weeklyDistanceChart: some View {
        VStack(alignment: .leading) {
            Text("Weekly Distance")
                .font(.headline)
            Chart(weeklyData) { week in
                BarMark(
                    x: .value("Week", week.id, unit: .weekOfYear),
                    y: .value("Distance", week.distance)
                )
                .foregroundStyle(.green)
            }
            .chartYAxisLabel("km")
            .frame(height: 200)
        }
    }

    private var weeklyCaloriesChart: some View {
        VStack(alignment: .leading) {
            Text("Weekly Calories")
                .font(.headline)
            Chart(weeklyData) { week in
                BarMark(
                    x: .value("Week", week.id, unit: .weekOfYear),
                    y: .value("Calories", week.calories)
                )
                .foregroundStyle(.orange)
            }
            .chartYAxisLabel("kcal")
            .frame(height: 200)
        }
    }

    private var avgSpeedTrendChart: some View {
        VStack(alignment: .leading) {
            Text("Average Speed Trend")
                .font(.headline)
            Chart(weeklyData) { week in
                LineMark(
                    x: .value("Week", week.id, unit: .weekOfYear),
                    y: .value("Avg Speed", week.avgSpeed)
                )
                .foregroundStyle(.blue)
                PointMark(
                    x: .value("Week", week.id, unit: .weekOfYear),
                    y: .value("Avg Speed", week.avgSpeed)
                )
                .foregroundStyle(.blue)
            }
            .chartYAxisLabel("km/h")
            .frame(height: 200)
        }
    }
}

private struct TrendStatCard: View {
    let label: String
    let value: String

    var body: some View {
        VStack(spacing: 4) {
            Text(value)
                .font(.title2.bold())
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
