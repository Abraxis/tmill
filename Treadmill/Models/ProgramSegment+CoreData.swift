// ~/src/tmill/Treadmill/Models/ProgramSegment+CoreData.swift
import CoreData
import Foundation

enum GoalType: String, CaseIterable {
    case distance = "distance"  // meters
    case time = "time"          // seconds
    case calories = "calories"  // kcal
}

@objc(ProgramSegment)
public class ProgramSegment: NSManagedObject {
    @NSManaged public var id: UUID
    @NSManaged public var order: Int16
    @NSManaged public var targetSpeed: Double
    @NSManaged public var targetIncline: Double
    @NSManaged public var goalType: String
    @NSManaged public var goalValue: Double
    @NSManaged public var program: WorkoutProgram?
}

extension ProgramSegment {
    var goalTypeEnum: GoalType {
        GoalType(rawValue: goalType) ?? .time
    }

    var goalDescription: String {
        switch goalTypeEnum {
        case .distance:
            return goalValue >= 1000 ? String(format: "%.1f km", goalValue / 1000) : "\(Int(goalValue))m"
        case .time:
            let min = Int(goalValue) / 60
            let sec = Int(goalValue) % 60
            return sec > 0 ? "\(min)m \(sec)s" : "\(min)m"
        case .calories:
            return "\(Int(goalValue)) cal"
        }
    }
}
