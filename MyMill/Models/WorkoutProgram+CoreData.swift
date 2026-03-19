// Models/WorkoutProgram+CoreData.swift
import CoreData
import Foundation

@objc(WorkoutProgram)
public class WorkoutProgram: NSManagedObject {
    @NSManaged public var id: UUID
    @NSManaged public var name: String
    @NSManaged public var createdAt: Date
    @NSManaged public var segments: NSOrderedSet
}

extension WorkoutProgram {
    var sortedSegments: [ProgramSegment] {
        segments.array as? [ProgramSegment] ?? []
    }
}
