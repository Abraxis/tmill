// ~/src/tmill/Treadmill/Models/WorkoutSession+CoreData.swift
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
}

extension WorkoutSession {
    /// Decoded speed samples for charting
    struct Sample: Codable {
        let time: Double    // seconds since session start
        let speed: Double   // km/h
        let incline: Double // percent
    }

    var samples: [Sample] {
        guard let data = speedSamples else { return [] }
        return (try? JSONDecoder().decode([Sample].self, from: data)) ?? []
    }

    var durationFormatted: String {
        let minutes = Int(duration) / 60
        let seconds = Int(duration) % 60
        return String(format: "%d:%02d", minutes, seconds)
    }

    var distanceKm: Double {
        distance / 1000.0
    }
}
