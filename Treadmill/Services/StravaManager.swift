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

    private let clientID = "55254"
    private let clientSecret = "6654203c4e9f8ce8551bc45732544e92fd19661f"
    private let redirectURI = "http://localhost:8089/callback"
    private let logger = Logger(subsystem: "com.mymill.app", category: "Strava")

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
        UserDefaults.standard.removeObject(forKey: "stravaTokens")
        isConnected = false
        athleteName = nil
        syncEnabled = false
    }

    // MARK: - Upload

    func uploadWorkout(
        startDate: Date,
        durationSeconds: Double,
        distanceMeters: Double,
        calories: Int,
        speedSamples: [(timeOffset: TimeInterval, speed: Double, distance: Double, altitude: Double)]
    ) async {
        guard syncEnabled, isConnected else { return }

        guard let token = await getValidToken() else {
            logger.warning("No valid Strava token, skipping upload")
            return
        }

        // Generate TCX
        let tcx = TCXGenerator.generate(
            startDate: startDate,
            totalTimeSeconds: durationSeconds,
            totalDistanceMeters: distanceMeters,
            calories: calories,
            trackPoints: speedSamples.map { sample in
                TCXGenerator.TrackPoint(
                    timeOffset: sample.timeOffset,
                    distanceMeters: sample.distance,
                    speedMPS: sample.speed / 3.6,
                    altitudeMeters: sample.altitude > 0 ? sample.altitude : nil
                )
            }
        )

        // Upload
        do {
            let uploadId = try await uploadTCX(tcx, token: token, name: "Treadmill Walk")
            logger.info("Strava upload submitted: \(uploadId)")

            // Poll for completion
            try? await Task.sleep(for: .seconds(3))
            let status = try await checkUploadStatus(uploadId, token: token)
            logger.info("Strava upload status: \(status)")
        } catch {
            logger.error("Strava upload failed: \(error.localizedDescription)")
        }
    }

    /// Re-upload a previously saved session to Strava
    func reuploadSession(_ session: WorkoutSession) async throws {
        guard isConnected else { throw StravaError.uploadFailed("Not connected to Strava") }

        guard let token = await getValidToken() else {
            throw StravaError.uploadFailed("No valid Strava token")
        }

        let samples = SessionTracker.buildStravaSamples(from: session.samples)

        let tcx = TCXGenerator.generate(
            startDate: session.date,
            totalTimeSeconds: session.duration,
            totalDistanceMeters: session.distance,
            calories: Int(session.calories),
            trackPoints: samples.map { sample in
                TCXGenerator.TrackPoint(
                    timeOffset: sample.timeOffset,
                    distanceMeters: sample.distance,
                    speedMPS: sample.speed / 3.6,
                    altitudeMeters: sample.altitude > 0 ? sample.altitude : nil
                )
            }
        )

        let uploadId = try await uploadTCX(tcx, token: token, name: "Treadmill Walk")
        logger.info("Strava re-upload submitted: \(uploadId)")

        try? await Task.sleep(for: .seconds(3))
        let status = try await checkUploadStatus(uploadId, token: token)
        logger.info("Strava re-upload status: \(status)")

        if status.contains("error") {
            throw StravaError.uploadFailed(status)
        }
    }

    // MARK: - Token Management

    private struct Tokens: Codable {
        var accessToken: String
        var refreshToken: String
        var expiresAt: Int
        var athleteName: String?

        var isExpired: Bool { Int(Date().timeIntervalSince1970) >= expiresAt }
    }

    private func saveTokens(_ tokens: Tokens) {
        if let data = try? JSONEncoder().encode(tokens) {
            UserDefaults.standard.set(data, forKey: "stravaTokens")
        }
    }

    private func loadTokens() -> Tokens? {
        guard let data = UserDefaults.standard.data(forKey: "stravaTokens") else { return nil }
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
                            continuation.resume(returning: code)
                        } else if request.contains("error=") {
                            let html = "HTTP/1.1 200 OK\r\nContent-Type: text/html\r\n\r\n<html><body><h2>Authorization denied</h2></body></html>"
                            connection.send(content: html.data(using: .utf8), completion: .contentProcessed { _ in
                                connection.cancel()
                            })
                            self?.httpListener?.cancel()
                            continuation.resume(throwing: StravaError.denied)
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
                continuation.resume(throwing: error)
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
        field("trainer", "1")
        field("external_id", UUID().uuidString)

        body.append("--\(boundary)\r\nContent-Disposition: form-data; name=\"file\"; filename=\"activity.tcx\"\r\nContent-Type: application/xml\r\n\r\n".data(using: .utf8)!)
        body.append(data)
        body.append("\r\n--\(boundary)--\r\n".data(using: .utf8)!)

        request.httpBody = body
        let (respData, _) = try await URLSession.shared.data(for: request)
        let json = try JSONSerialization.jsonObject(with: respData) as? [String: Any] ?? [:]
        return "\(json["id"] ?? "unknown")"
    }

    private func checkUploadStatus(_ uploadId: String, token: String) async throws -> String {
        var request = URLRequest(url: URL(string: "https://www.strava.com/api/v3/uploads/\(uploadId)")!)
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        let (data, _) = try await URLSession.shared.data(for: request)
        let json = try JSONSerialization.jsonObject(with: data) as? [String: Any] ?? [:]
        return json["status"] as? String ?? "unknown"
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

enum StravaError: Error {
    case denied
    case uploadFailed(String)
}
