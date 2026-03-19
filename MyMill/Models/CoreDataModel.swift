// Models/CoreDataModel.swift
import CoreData

enum CoreDataModel {
    static func create() -> NSManagedObjectModel {
        let model = NSManagedObjectModel()

        // MARK: - WorkoutSession Entity
        let session = NSEntityDescription()
        session.name = "WorkoutSession"
        session.managedObjectClassName = "WorkoutSession"

        let sessionId = NSAttributeDescription()
        sessionId.name = "id"
        sessionId.attributeType = .UUIDAttributeType
        sessionId.isOptional = false

        let sessionDate = NSAttributeDescription()
        sessionDate.name = "date"
        sessionDate.attributeType = .dateAttributeType
        sessionDate.isOptional = false

        let sessionDuration = NSAttributeDescription()
        sessionDuration.name = "duration"
        sessionDuration.attributeType = .doubleAttributeType
        sessionDuration.defaultValue = 0.0

        let sessionDistance = NSAttributeDescription()
        sessionDistance.name = "distance"
        sessionDistance.attributeType = .doubleAttributeType
        sessionDistance.defaultValue = 0.0

        let sessionCalories = NSAttributeDescription()
        sessionCalories.name = "calories"
        sessionCalories.attributeType = .integer32AttributeType
        sessionCalories.defaultValue = 0

        let sessionAvgSpeed = NSAttributeDescription()
        sessionAvgSpeed.name = "avgSpeed"
        sessionAvgSpeed.attributeType = .doubleAttributeType
        sessionAvgSpeed.defaultValue = 0.0

        let sessionMaxSpeed = NSAttributeDescription()
        sessionMaxSpeed.name = "maxSpeed"
        sessionMaxSpeed.attributeType = .doubleAttributeType
        sessionMaxSpeed.defaultValue = 0.0

        let sessionAvgIncline = NSAttributeDescription()
        sessionAvgIncline.name = "avgIncline"
        sessionAvgIncline.attributeType = .doubleAttributeType
        sessionAvgIncline.defaultValue = 0.0

        let sessionSpeedSamples = NSAttributeDescription()
        sessionSpeedSamples.name = "speedSamples"
        sessionSpeedSamples.attributeType = .binaryDataAttributeType
        sessionSpeedSamples.isOptional = true

        let sessionElevationGain = NSAttributeDescription()
        sessionElevationGain.name = "elevationGain"
        sessionElevationGain.attributeType = .doubleAttributeType
        sessionElevationGain.defaultValue = 0.0

        let sessionAvgHeartRate = NSAttributeDescription()
        sessionAvgHeartRate.name = "avgHeartRate"
        sessionAvgHeartRate.attributeType = .doubleAttributeType
        sessionAvgHeartRate.defaultValue = 0.0

        let sessionMaxHeartRate = NSAttributeDescription()
        sessionMaxHeartRate.name = "maxHeartRate"
        sessionMaxHeartRate.attributeType = .doubleAttributeType
        sessionMaxHeartRate.defaultValue = 0.0

        let sessionHeartRateSamples = NSAttributeDescription()
        sessionHeartRateSamples.name = "heartRateSamples"
        sessionHeartRateSamples.attributeType = .binaryDataAttributeType
        sessionHeartRateSamples.isOptional = true

        let sessionStravaActivityId = NSAttributeDescription()
        sessionStravaActivityId.name = "stravaActivityId"
        sessionStravaActivityId.attributeType = .stringAttributeType
        sessionStravaActivityId.isOptional = true

        session.properties = [
            sessionId, sessionDate, sessionDuration, sessionDistance,
            sessionCalories, sessionAvgSpeed, sessionMaxSpeed,
            sessionAvgIncline, sessionSpeedSamples, sessionElevationGain,
            sessionAvgHeartRate, sessionMaxHeartRate, sessionHeartRateSamples,
            sessionStravaActivityId
        ]

        // MARK: - WorkoutProgram Entity
        let program = NSEntityDescription()
        program.name = "WorkoutProgram"
        program.managedObjectClassName = "WorkoutProgram"

        let programId = NSAttributeDescription()
        programId.name = "id"
        programId.attributeType = .UUIDAttributeType
        programId.isOptional = false

        let programName = NSAttributeDescription()
        programName.name = "name"
        programName.attributeType = .stringAttributeType
        programName.isOptional = false

        let programCreatedAt = NSAttributeDescription()
        programCreatedAt.name = "createdAt"
        programCreatedAt.attributeType = .dateAttributeType
        programCreatedAt.isOptional = false

        // MARK: - ProgramSegment Entity
        let segment = NSEntityDescription()
        segment.name = "ProgramSegment"
        segment.managedObjectClassName = "ProgramSegment"

        let segmentId = NSAttributeDescription()
        segmentId.name = "id"
        segmentId.attributeType = .UUIDAttributeType
        segmentId.isOptional = false

        let segmentOrder = NSAttributeDescription()
        segmentOrder.name = "order"
        segmentOrder.attributeType = .integer16AttributeType
        segmentOrder.defaultValue = 0

        let segmentSpeed = NSAttributeDescription()
        segmentSpeed.name = "targetSpeed"
        segmentSpeed.attributeType = .doubleAttributeType
        segmentSpeed.defaultValue = 1.0

        let segmentIncline = NSAttributeDescription()
        segmentIncline.name = "targetIncline"
        segmentIncline.attributeType = .doubleAttributeType
        segmentIncline.defaultValue = 0.0

        let segmentGoalType = NSAttributeDescription()
        segmentGoalType.name = "goalType"
        segmentGoalType.attributeType = .stringAttributeType
        segmentGoalType.isOptional = false

        let segmentGoalValue = NSAttributeDescription()
        segmentGoalValue.name = "goalValue"
        segmentGoalValue.attributeType = .doubleAttributeType
        segmentGoalValue.defaultValue = 0.0

        // MARK: - Relationships
        let programToSegments = NSRelationshipDescription()
        programToSegments.name = "segments"
        programToSegments.destinationEntity = segment
        programToSegments.isOrdered = true
        programToSegments.minCount = 0
        programToSegments.maxCount = 0  // to-many
        programToSegments.deleteRule = .cascadeDeleteRule

        let segmentToProgram = NSRelationshipDescription()
        segmentToProgram.name = "program"
        segmentToProgram.destinationEntity = program
        segmentToProgram.minCount = 1
        segmentToProgram.maxCount = 1  // to-one
        segmentToProgram.deleteRule = .nullifyDeleteRule

        // Set inverse relationships
        programToSegments.inverseRelationship = segmentToProgram
        segmentToProgram.inverseRelationship = programToSegments

        program.properties = [programId, programName, programCreatedAt, programToSegments]
        segment.properties = [segmentId, segmentOrder, segmentSpeed, segmentIncline,
                              segmentGoalType, segmentGoalValue, segmentToProgram]

        model.entities = [session, program, segment]
        return model
    }
}
