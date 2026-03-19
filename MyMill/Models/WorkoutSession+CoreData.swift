// Models/WorkoutSession+CoreData.swift
import CoreData
import Foundation

@objc(WorkoutSession)
public class WorkoutSession: NSManagedObject {
    @NSManaged public var id: UUID
    @NSManaged public var date: Date
    @NSManaged public var duration: Double
    @NSManaged public var distance: Double
    @NSManaged public var calories: Int32
    @NSManaged public var avgSpeed: Double
    @NSManaged public var maxSpeed: Double
    @NSManaged public var avgIncline: Double
    @NSManaged public var speedSamples: Data?
    @NSManaged public var elevationGain: Double
    @NSManaged public var avgHeartRate: Double
    @NSManaged public var maxHeartRate: Double
    @NSManaged public var heartRateSamples: Data?
    @NSManaged public var stravaActivityId: String?
}

extension WorkoutSession {
    /// Decoded speed samples for charting
    struct Sample: Codable {
        let time: Double    // seconds since session start
        let speed: Double   // km/h
        let incline: Double // percent
    }

    struct HeartRateSample: Codable {
        let time: Double  // seconds since session start
        let bpm: Int
    }

    var samples: [Sample] {
        guard let data = speedSamples else { return [] }
        return (try? JSONDecoder().decode([Sample].self, from: data)) ?? []
    }

    var hrSamples: [HeartRateSample] {
        guard let data = heartRateSamples else { return [] }
        return (try? JSONDecoder().decode([HeartRateSample].self, from: data)) ?? []
    }

    var durationFormatted: String {
        let minutes = Int(duration) / 60
        let seconds = Int(duration) % 60
        return String(format: "%d:%02d", minutes, seconds)
    }

    var distanceKm: Double {
        distance / 1000.0
    }

    /// Elevation gain in meters — uses stored value if available, otherwise computes from samples
    var computedElevationGain: Double {
        if elevationGain > 0 { return elevationGain }
        return Self.calculateElevationGain(from: samples)
    }

    /// Remove trailing zero-speed samples (from hysteresis after treadmill stops)
    static func trimTrailingZeros(from samples: [Sample]) -> [Sample] {
        guard !samples.isEmpty else { return samples }
        var end = samples.count
        while end > 0 && samples[end - 1].speed <= 0 {
            end -= 1
        }
        return Array(samples[0..<end])
    }

    /// Extrapolate the initial gap by backfilling from the first non-zero sample
    static func extrapolateInitialGap(in samples: [Sample], interval: TimeInterval = 2.0) -> [Sample] {
        guard let firstNonZero = samples.first(where: { $0.speed > 0 }), firstNonZero.time > interval else {
            return samples
        }
        var filled: [Sample] = []
        var t = 0.0
        while t < firstNonZero.time {
            filled.append(Sample(time: t, speed: firstNonZero.speed, incline: firstNonZero.incline))
            t += interval
        }
        // Append original samples starting from the first non-zero
        if let idx = samples.firstIndex(where: { $0.speed > 0 }) {
            filled.append(contentsOf: samples[idx...])
        }
        return filled
    }

    /// Calculate total vertical climb from time-series samples
    static func calculateElevationGain(from samples: [Sample]) -> Double {
        guard samples.count >= 2 else { return 0 }
        var total = 0.0
        for i in 1..<samples.count {
            let dt = samples[i].time - samples[i - 1].time
            guard dt > 0 else { continue }
            let incline = samples[i].incline
            guard incline > 0 else { continue }
            // distance in meters for this interval
            let distMeters = (samples[i].speed / 3.6) * dt
            // vertical rise: grade = incline% / 100
            total += distMeters * (incline / 100.0)
        }
        return total
    }
}
