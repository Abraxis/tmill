// Services/HealthExportParser.swift
import Foundation
import os

/// Streams Apple Health export.xml (SAX parser) to extract heart rate samples
/// within a time window. Handles multi-GB files without loading into memory.
/// Also accepts .zip files and extracts export.xml automatically.
final class HealthExportParser: NSObject, XMLParserDelegate {
    private var parser: XMLParser?
    private let startDate: Date
    private let endDate: Date
    private var samples: [WorkoutSession.HeartRateSample] = []
    private var tempURL: URL?

    private let logger = Logger(subsystem: "com.mymill.app", category: "HealthExport")

    private static let dateFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd HH:mm:ss Z"
        f.locale = Locale(identifier: "en_US_POSIX")
        return f
    }()

    init?(url: URL, from startDate: Date, to endDate: Date) {
        self.startDate = startDate
        self.endDate = endDate
        super.init()

        let resolvedURL: URL
        if url.pathExtension.lowercased() == "zip" {
            guard let extracted = extractXMLFromZip(url) else {
                logger.error("Could not extract export.xml from ZIP")
                return nil
            }
            resolvedURL = extracted
            tempURL = extracted
        } else {
            resolvedURL = url
        }

        guard let stream = InputStream(url: resolvedURL) else {
            logger.error("Could not open input stream for \(resolvedURL.path)")
            return nil
        }
        let xmlParser = XMLParser(stream: stream)
        xmlParser.delegate = self
        self.parser = xmlParser
    }

    deinit {
        if let tempURL {
            try? FileManager.default.removeItem(at: tempURL)
        }
    }

    func parse() -> [WorkoutSession.HeartRateSample] {
        logger.info("Parsing Health export for HR between \(self.startDate) and \(self.endDate)")
        parser?.parse()
        logger.info("Found \(self.samples.count) HR samples")
        return samples.sorted { $0.time < $1.time }
    }

    // MARK: - XMLParserDelegate

    func parser(_ parser: XMLParser, didStartElement elementName: String,
                namespaceURI: String?, qualifiedName: String?,
                attributes: [String: String]) {
        guard elementName == "Record",
              attributes["type"] == "HKQuantityTypeIdentifierHeartRate",
              let dateStr = attributes["startDate"],
              let valueStr = attributes["value"],
              let date = Self.dateFormatter.date(from: dateStr),
              let bpm = Double(valueStr)
        else { return }

        guard date >= startDate && date <= endDate else { return }

        let sample = WorkoutSession.HeartRateSample(
            time: date.timeIntervalSince(startDate),
            bpm: Int(bpm.rounded())
        )
        samples.append(sample)
    }

    // MARK: - ZIP Extraction

    /// Extract export.xml from a Health export ZIP using the built-in /usr/bin/unzip
    private func extractXMLFromZip(_ zipURL: URL) -> URL? {
        let tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("mymill_health_\(UUID().uuidString)", isDirectory: true)
        do {
            try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        } catch {
            return nil
        }

        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/unzip")
        // Only extract export.xml, skip everything else
        process.arguments = ["-o", "-j", zipURL.path, "apple_health_export/export.xml", "-d", tempDir.path]
        process.standardOutput = nil
        process.standardError = nil

        do {
            try process.run()
            process.waitUntilExit()
        } catch {
            return nil
        }

        let xmlURL = tempDir.appendingPathComponent("export.xml")
        guard FileManager.default.fileExists(atPath: xmlURL.path) else { return nil }
        return xmlURL
    }
}
