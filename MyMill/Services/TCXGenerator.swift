import Foundation

enum TCXGenerator {
    struct TrackPoint {
        let timeOffset: TimeInterval   // seconds from start
        let distanceMeters: Double      // cumulative
        let speedMPS: Double?           // meters per second
        let altitudeMeters: Double?     // cumulative elevation
        let heartRateBPM: Int?          // beats per minute
    }

    static func generate(
        startDate: Date,
        totalTimeSeconds: Double,
        totalDistanceMeters: Double,
        calories: Int?,
        trackPoints: [TrackPoint]
    ) -> Data {
        let fmt = ISO8601DateFormatter()
        let startStr = fmt.string(from: startDate)

        var xml = """
        <?xml version="1.0" encoding="UTF-8"?>
        <TrainingCenterDatabase
          xmlns="http://www.garmin.com/xmlschemas/TrainingCenterDatabase/v2"
          xmlns:ax="http://www.garmin.com/xmlschemas/ActivityExtension/v2">
        <Activities>
        <Activity Sport="Other">
        <Id>\(startStr)</Id>
        <Lap StartTime="\(startStr)">
        <TotalTimeSeconds>\(String(format: "%.0f", totalTimeSeconds))</TotalTimeSeconds>
        <DistanceMeters>\(String(format: "%.1f", totalDistanceMeters))</DistanceMeters>

        """

        if let cal = calories, cal > 0 {
            xml += "<Calories>\(cal)</Calories>\n"
        }

        xml += """
        <Intensity>Active</Intensity>
        <TriggerMethod>Manual</TriggerMethod>
        <Track>

        """

        for point in trackPoints {
            let pointDate = startDate.addingTimeInterval(point.timeOffset)
            let timeStr = fmt.string(from: pointDate)

            xml += "<Trackpoint>\n"
            xml += "<Time>\(timeStr)</Time>\n"
            xml += "<DistanceMeters>\(String(format: "%.1f", point.distanceMeters))</DistanceMeters>\n"

            if let alt = point.altitudeMeters {
                xml += "<AltitudeMeters>\(String(format: "%.1f", alt))</AltitudeMeters>\n"
            }

            // Include grade/incline as extension for Strava
            // (altitude changes encode elevation; grade is informational)

            if let hr = point.heartRateBPM, hr > 0 {
                xml += "<HeartRateBpm><Value>\(hr)</Value></HeartRateBpm>\n"
            }

            if let speed = point.speedMPS, speed > 0 {
                xml += "<Extensions><ax:TPX><ax:Speed>\(String(format: "%.2f", speed))</ax:Speed></ax:TPX></Extensions>\n"
            }

            xml += "</Trackpoint>\n"
        }

        xml += """
        </Track>
        </Lap>
        </Activity>
        </Activities>
        </TrainingCenterDatabase>
        """

        return xml.data(using: .utf8)!
    }
}
