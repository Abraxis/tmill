import Foundation
import AppKit
import Network
import os

@Observable
final class StravaManager {
    static let shared = StravaManager()

    private(set) var isConnected = false
    private(set) var athleteName: String?
    var syncEnabled: Bool {
        didSet { UserDefaults.standard.set(syncEnabled, forKey: "stravaSyncEnabled") }
    }

    private var clientID: String { SettingsManager.shared.stravaClientID }
    private var clientSecret: String { SettingsManager.shared.stravaClientSecret }
    private var redirectURI: String { SettingsManager.shared.stravaRedirectURI }
    private let logger = Logger(subsystem: "com.mymill.app", category: "Strava")

    var isConfigured: Bool {
        !clientID.isEmpty && !clientSecret.isEmpty
    }

    private var httpListener: NWListener?

    private init() {
        syncEnabled = UserDefaults.standard.bool(forKey: "stravaSyncEnabled")
        if let tokens = loadTokens() {
            isConnected = true
            athleteName = tokens.athleteName
        }
    }

    // MARK: - OAuth2

    func authorize() async throws {
        guard isConfigured else {
            throw StravaError.uploadFailed("Strava API credentials not configured — check Settings")
        }
        let code = try await startLocalServerAndGetCode()
        let tokens = try await exchangeCode(code)
        saveTokens(tokens)
        await MainActor.run {
            isConnected = true
            athleteName = tokens.athleteName
            syncEnabled = true
        }
        logger.info("Strava connected: \(tokens.athleteName ?? "unknown")")
    }

    func disconnect() {
        let deleteQuery: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: Self.keychainService,
            kSecAttrAccount as String: Self.keychainAccount,
        ]
        SecItemDelete(deleteQuery as CFDictionary)
        isConnected = false
        athleteName = nil
        syncEnabled = false
    }

    // MARK: - Upload

    @discardableResult
    func uploadWorkout(
        startDate: Date,
        durationSeconds: Double,
        distanceMeters: Double,
        calories: Int,
        speedSamples: [(timeOffset: TimeInterval, speed: Double, distance: Double, altitude: Double)],
        heartRateSamples: [(timeOffset: TimeInterval, bpm: Int)] = []
    ) async -> Int64? {
        guard syncEnabled, isConnected else { return nil }

        guard let token = await getValidToken() else {
            logger.warning("No valid Strava token, skipping upload")
            return nil
        }

        // Generate TCX with HR interpolation
        let tcx = TCXGenerator.generate(
            startDate: startDate,
            totalTimeSeconds: durationSeconds,
            totalDistanceMeters: distanceMeters,
            calories: calories,
            trackPoints: speedSamples.map { sample in
                let nearestHR = heartRateSamples.min(by: {
                    abs($0.timeOffset - sample.timeOffset) < abs($1.timeOffset - sample.timeOffset)
                })
                return TCXGenerator.TrackPoint(
                    timeOffset: sample.timeOffset,
                    distanceMeters: sample.distance,
                    speedMPS: sample.speed / 3.6,
                    altitudeMeters: sample.altitude,
                    heartRateBPM: nearestHR?.bpm
                )
            }
        )

        // Upload and poll for activity ID
        do {
            let uploadId = try await uploadTCX(tcx, token: token, name: "MyMill Walk")
            logger.info("Strava upload submitted: \(uploadId)")
            let activityId = await pollForActivityId(uploadId, token: token)
            if let activityId {
                await updateActivity(activityId, token: token)
            }
            return activityId
        } catch {
            logger.error("Strava upload failed: \(error.localizedDescription)")
            return nil
        }
    }

    /// Check if a Strava activity already exists overlapping the given time window
    func findExistingActivity(startDate: Date, duration: TimeInterval, token: String) async -> (id: Int64, name: String)? {
        // Search for activities around the session time
        let before = Int(startDate.addingTimeInterval(duration + 3600).timeIntervalSince1970)
        let after = Int(startDate.addingTimeInterval(-3600).timeIntervalSince1970)
        var request = URLRequest(url: URL(string: "https://www.strava.com/api/v3/athlete/activities?before=\(before)&after=\(after)&per_page=10")!)
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")

        guard let (data, _) = try? await URLSession.shared.data(for: request),
              let activities = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]] else {
            return nil
        }

        for activity in activities {
            guard let dateStr = activity["start_date"] as? String,
                  let actId = (activity["id"] as? NSNumber)?.int64Value,
                  let name = activity["name"] as? String else { continue }
            let fmt = ISO8601DateFormatter()
            guard let actDate = fmt.date(from: dateStr) else { continue }
            // Check if the activity overlaps with our session (within 5 minutes)
            if abs(actDate.timeIntervalSince(startDate)) < 300 {
                return (id: actId, name: name)
            }
        }
        return nil
    }

    /// Re-upload a previously saved session to Strava
    @discardableResult
    func reuploadSession(_ session: WorkoutSession) async throws -> Int64? {
        guard isConnected else { throw StravaError.uploadFailed("Not connected to Strava") }

        guard let token = await getValidToken() else {
            throw StravaError.uploadFailed("No valid Strava token")
        }

        // Check for existing activity
        if let existing = await findExistingActivity(startDate: session.date, duration: session.duration, token: token) {
            throw StravaError.duplicate(activityId: existing.id, name: existing.name)
        }

        let samples = SessionTracker.buildStravaSamples(from: session.samples)
        let hrSamples = session.hrSamples.map { (timeOffset: $0.time, bpm: $0.bpm) }

        let tcx = TCXGenerator.generate(
            startDate: session.date,
            totalTimeSeconds: session.duration,
            totalDistanceMeters: session.distance,
            calories: Int(session.calories),
            trackPoints: samples.map { sample in
                let nearestHR = hrSamples.min(by: {
                    abs($0.timeOffset - sample.timeOffset) < abs($1.timeOffset - sample.timeOffset)
                })
                return TCXGenerator.TrackPoint(
                    timeOffset: sample.timeOffset,
                    distanceMeters: sample.distance,
                    speedMPS: sample.speed / 3.6,
                    altitudeMeters: sample.altitude,
                    heartRateBPM: nearestHR?.bpm
                )
            }
        )

        let uploadId = try await uploadTCX(tcx, token: token, name: "MyMill Walk")
        logger.info("Strava re-upload submitted: \(uploadId)")

        let activityId = await pollForActivityId(uploadId, token: token)

        if let activityId {
            await updateActivity(activityId, token: token)
        } else {
            if let result = try? await checkUploadStatus(uploadId, token: token),
               result.status.contains("error") {
                throw StravaError.uploadFailed(result.status)
            }
        }

        return activityId
    }

    // MARK: - Token Management

    private struct Tokens: Codable {
        var accessToken: String
        var refreshToken: String
        var expiresAt: Int
        var athleteName: String?

        var isExpired: Bool { Int(Date().timeIntervalSince1970) >= expiresAt }
    }

    private static let keychainService = "com.mymill.strava"
    private static let keychainAccount = "tokens"

    private func saveTokens(_ tokens: Tokens) {
        guard let data = try? JSONEncoder().encode(tokens) else { return }

        // Delete existing item first
        let deleteQuery: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: Self.keychainService,
            kSecAttrAccount as String: Self.keychainAccount,
        ]
        SecItemDelete(deleteQuery as CFDictionary)

        let addQuery: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: Self.keychainService,
            kSecAttrAccount as String: Self.keychainAccount,
            kSecValueData as String: data,
        ]
        SecItemAdd(addQuery as CFDictionary, nil)
    }

    private func loadTokens() -> Tokens? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: Self.keychainService,
            kSecAttrAccount as String: Self.keychainAccount,
            kSecReturnData as String: true,
        ]
        var result: AnyObject?
        guard SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess,
              let data = result as? Data else {
            // Migrate from UserDefaults if present
            if let legacyData = UserDefaults.standard.data(forKey: "stravaTokens"),
               let tokens = try? JSONDecoder().decode(Tokens.self, from: legacyData) {
                saveTokens(tokens)
                UserDefaults.standard.removeObject(forKey: "stravaTokens")
                return tokens
            }
            return nil
        }
        return try? JSONDecoder().decode(Tokens.self, from: data)
    }

    private func getValidToken() async -> String? {
        guard var tokens = loadTokens() else { return nil }
        if tokens.isExpired {
            guard let refreshed = try? await refreshTokens(tokens.refreshToken) else { return nil }
            tokens = refreshed
            saveTokens(tokens)
        }
        return tokens.accessToken
    }

    // MARK: - OAuth HTTP

    private func startLocalServerAndGetCode() async throws -> String {
        try await withCheckedThrowingContinuation { continuation in
            var resumed = false
            let resumeOnce: (Result<String, Error>) -> Void = { result in
                guard !resumed else { return }
                resumed = true
                switch result {
                case .success(let value): continuation.resume(returning: value)
                case .failure(let error): continuation.resume(throwing: error)
                }
            }

            do {
                let params = NWParameters.tcp
                httpListener = try NWListener(using: params, on: 8089)

                httpListener?.newConnectionHandler = { [weak self] connection in
                    connection.start(queue: .main)
                    connection.receive(minimumIncompleteLength: 1, maximumLength: 65536) { data, _, _, _ in
                        guard let data, let request = String(data: data, encoding: .utf8) else { return }

                        if let code = self?.extractCode(from: request) {
                            let html = "HTTP/1.1 200 OK\r\nContent-Type: text/html\r\n\r\n<html><body><h2>Connected to Strava!</h2><p>You can close this window.</p></body></html>"
                            connection.send(content: html.data(using: .utf8), completion: .contentProcessed { _ in
                                connection.cancel()
                            })
                            self?.httpListener?.cancel()
                            resumeOnce(.success(code))
                        } else if request.contains("error=") {
                            let html = "HTTP/1.1 200 OK\r\nContent-Type: text/html\r\n\r\n<html><body><h2>Authorization denied</h2></body></html>"
                            connection.send(content: html.data(using: .utf8), completion: .contentProcessed { _ in
                                connection.cancel()
                            })
                            self?.httpListener?.cancel()
                            resumeOnce(.failure(StravaError.denied))
                        }
                    }
                }

                httpListener?.start(queue: .main)

                // Open browser
                var url = URLComponents(string: "https://www.strava.com/oauth/authorize")!
                url.queryItems = [
                    URLQueryItem(name: "client_id", value: clientID),
                    URLQueryItem(name: "redirect_uri", value: redirectURI),
                    URLQueryItem(name: "response_type", value: "code"),
                    URLQueryItem(name: "scope", value: "activity:write"),
                    URLQueryItem(name: "approval_prompt", value: "auto"),
                ]
                NSWorkspace.shared.open(url.url!)
            } catch {
                resumeOnce(.failure(error))
            }
        }
    }

    private func extractCode(from httpRequest: String) -> String? {
        guard let firstLine = httpRequest.split(separator: "\r\n").first else { return nil }
        let parts = firstLine.split(separator: " ")
        guard parts.count >= 2 else { return nil }
        let path = "http://localhost:8089\(parts[1])"
        guard let components = URLComponents(string: path) else { return nil }
        return components.queryItems?.first(where: { $0.name == "code" })?.value
    }

    private func exchangeCode(_ code: String) async throws -> Tokens {
        let body = "client_id=\(clientID)&client_secret=\(clientSecret)&code=\(code)&grant_type=authorization_code"
        let json = try await postForm("https://www.strava.com/oauth/token", body: body)

        let athlete = json["athlete"] as? [String: Any]
        let firstName = athlete?["firstname"] as? String
        let lastName = athlete?["lastname"] as? String
        let name = [firstName, lastName].compactMap { $0 }.joined(separator: " ")

        return Tokens(
            accessToken: json["access_token"] as? String ?? "",
            refreshToken: json["refresh_token"] as? String ?? "",
            expiresAt: json["expires_at"] as? Int ?? 0,
            athleteName: name.isEmpty ? nil : name
        )
    }

    private func refreshTokens(_ refreshToken: String) async throws -> Tokens {
        let body = "client_id=\(clientID)&client_secret=\(clientSecret)&grant_type=refresh_token&refresh_token=\(refreshToken)"
        let json = try await postForm("https://www.strava.com/oauth/token", body: body)

        var tokens = loadTokens() ?? Tokens(accessToken: "", refreshToken: "", expiresAt: 0)
        tokens.accessToken = json["access_token"] as? String ?? ""
        tokens.refreshToken = json["refresh_token"] as? String ?? ""
        tokens.expiresAt = json["expires_at"] as? Int ?? 0
        return tokens
    }

    // MARK: - Upload API

    private func uploadTCX(_ data: Data, token: String, name: String) async throws -> String {
        let boundary = UUID().uuidString
        var request = URLRequest(url: URL(string: "https://www.strava.com/api/v3/uploads")!)
        request.httpMethod = "POST"
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.setValue("multipart/form-data; boundary=\(boundary)", forHTTPHeaderField: "Content-Type")

        var body = Data()
        func field(_ name: String, _ value: String) {
            body.append("--\(boundary)\r\nContent-Disposition: form-data; name=\"\(name)\"\r\n\r\n\(value)\r\n".data(using: .utf8)!)
        }
        field("data_type", "tcx")
        field("sport_type", "Walk")
        field("name", name)
        field("external_id", UUID().uuidString)

        body.append("--\(boundary)\r\nContent-Disposition: form-data; name=\"file\"; filename=\"activity.tcx\"\r\nContent-Type: application/xml\r\n\r\n".data(using: .utf8)!)
        body.append(data)
        body.append("\r\n--\(boundary)--\r\n".data(using: .utf8)!)

        request.httpBody = body
        let (respData, resp) = try await URLSession.shared.data(for: request)
        let httpStatus = (resp as? HTTPURLResponse)?.statusCode ?? 0
        let json = try JSONSerialization.jsonObject(with: respData) as? [String: Any] ?? [:]
        logger.info("Strava upload response: HTTP \(httpStatus, privacy: .public), body=\(String(data: respData, encoding: .utf8) ?? "nil", privacy: .public)")
        if let error = json["error"] as? String {
            throw StravaError.uploadFailed("HTTP \(httpStatus): \(error)")
        }
        if let errors = json["errors"] as? [[String: Any]] {
            let msg = errors.map { "\($0["field"] ?? ""):\($0["code"] ?? "")" }.joined(separator: ", ")
            throw StravaError.uploadFailed("HTTP \(httpStatus): \(msg)")
        }
        return "\(json["id"] ?? "unknown")"
    }

    private func checkUploadStatus(_ uploadId: String, token: String) async throws -> StravaUploadResult {
        var request = URLRequest(url: URL(string: "https://www.strava.com/api/v3/uploads/\(uploadId)")!)
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        let (data, _) = try await URLSession.shared.data(for: request)
        let json = try JSONSerialization.jsonObject(with: data) as? [String: Any] ?? [:]
        let status = json["status"] as? String ?? "unknown"
        let activityId = (json["activity_id"] as? NSNumber)?.int64Value
        return StravaUploadResult(status: status, activityId: activityId)
    }

    private func pollForActivityId(_ uploadId: String, token: String) async -> Int64? {
        for attempt in 1...3 {
            try? await Task.sleep(for: .seconds(5))
            guard let result = try? await checkUploadStatus(uploadId, token: token) else { continue }
            logger.info("Strava poll attempt \(attempt): status=\(result.status, privacy: .public), activityId=\(String(describing: result.activityId), privacy: .public)")
            if let activityId = result.activityId {
                return activityId
            }
            if result.status.contains("error") {
                logger.error("Strava upload error: \(result.status, privacy: .public)")
                return nil
            }
        }
        return nil
    }

    /// Update activity to ensure trainer flag is off (so Strava preserves elevation data)
    private func updateActivity(_ activityId: Int64, token: String) async {
        var request = URLRequest(url: URL(string: "https://www.strava.com/api/v3/activities/\(activityId)")!)
        request.httpMethod = "PUT"
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = #"{"trainer":false,"sport_type":"Walk"}"#.data(using: .utf8)
        do {
            let (data, _) = try await URLSession.shared.data(for: request)
            logger.info("Strava activity update: \(String(data: data, encoding: .utf8)?.prefix(200) ?? "nil", privacy: .public)")
        } catch {
            logger.error("Strava activity update failed: \(error.localizedDescription, privacy: .public)")
        }
    }

    // MARK: - Helpers

    private func postForm(_ urlString: String, body: String) async throws -> [String: Any] {
        var request = URLRequest(url: URL(string: urlString)!)
        request.httpMethod = "POST"
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        request.httpBody = body.data(using: .utf8)
        let (data, _) = try await URLSession.shared.data(for: request)
        return (try? JSONSerialization.jsonObject(with: data) as? [String: Any]) ?? [:]
    }
}

enum StravaError: LocalizedError {
    case denied
    case uploadFailed(String)
    case duplicate(activityId: Int64, name: String)

    var errorDescription: String? {
        switch self {
        case .denied: return "Strava authorization was denied"
        case .uploadFailed(let msg): return msg
        case .duplicate(let id, let name):
            return "Activity \"\(name)\" already exists on Strava (ID: \(id)). Delete it on Strava first, then re-upload."
        }
    }
}

struct StravaUploadResult {
    let status: String
    let activityId: Int64?
}
