import Foundation

/// Thin async API layer for the /api/experiments endpoints.
/// Mirrors the BackendAPI pattern used throughout the app.
enum ExperimentService {

    private static let decoder: JSONDecoder = {
        let d = JSONDecoder()
        d.keyDecodingStrategy  = .convertFromSnakeCase
        return d
    }()

    private static let encoder: JSONEncoder = {
        let e = JSONEncoder()
        e.keyEncodingStrategy  = .convertToSnakeCase
        return e
    }()

    // MARK: - Endpoints

    static func checkBackground() async throws -> BackgroundStatus {
        let req = try authorizedGET("/api/experiments/check-background")
        return try await perform(req)
    }

    static func getAvailable() async throws -> [AvailableExperiment] {
        let req = try authorizedGET("/api/experiments/available")
        return try await perform(req)
    }

    static func start(_ request: StartExperimentRequest) async throws -> ExperimentModel {
        var req = try authorizedPOST("/api/experiments")
        req.httpBody = try encoder.encode(request)
        return try await perform(req)
    }

    static func get(id: UUID) async throws -> ExperimentModel {
        let req = try authorizedGET("/api/experiments/\(id)")
        return try await perform(req)
    }

    static func recordReading(experimentId: UUID, reading: RecordReadingRequest) async throws -> ExperimentModel {
        var req = try authorizedPOST("/api/experiments/\(experimentId)/reading")
        req.httpBody = try encoder.encode(reading)
        return try await perform(req)
    }

    static func complete(experimentId: UUID) async throws -> ExperimentResult {
        let req = try authorizedPOST("/api/experiments/\(experimentId)/complete")
        return try await perform(req)
    }

    static func abandon(experimentId: UUID) async throws -> ExperimentModel {
        let req = try authorizedPOST("/api/experiments/\(experimentId)/abandon")
        return try await perform(req)
    }

    static func getHistory() async throws -> [ExperimentModel] {
        let req = try authorizedGET("/api/experiments")
        return try await perform(req)
    }

    // MARK: - Helpers

    private static func authorizedGET(_ path: String) throws -> URLRequest {
        try buildRequest(path: path, method: "GET")
    }

    private static func authorizedPOST(_ path: String) throws -> URLRequest {
        try buildRequest(path: path, method: "POST")
    }

    private static func buildRequest(path: String, method: String) throws -> URLRequest {
        guard let token = GlucoseMonitorAPI.storedAccessToken(), !token.isEmpty else {
            throw GlucoseMonitorAPI.APIError.missingToken
        }
        let base = GlucoseMonitorAPI.effectiveBackendBaseURL()
        guard let url = URL(string: base + path) else {
            throw GlucoseMonitorAPI.APIError.invalidURL
        }
        var req = URLRequest(url: url)
        req.httpMethod = method
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.setValue("Bearer \(token)",  forHTTPHeaderField: "Authorization")
        return req
    }

    private static func perform<T: Decodable>(_ request: URLRequest) async throws -> T {
        let (data, response) = try await URLSession.shared.data(for: request)
        try BackendAPI.checkStatus(response, data: data)
        return try decoder.decode(T.self, from: data)
    }
}

// Expose BackendAPI.checkStatus (it is internal in BackendAPI.swift)
private extension BackendAPI {
    static func checkStatus(_ response: URLResponse, data: Data) throws {
        guard let http = response as? HTTPURLResponse else { return }
        guard (200..<300).contains(http.statusCode) else {
            let body = String(data: data, encoding: .utf8) ?? ""
            throw GlucoseMonitorAPI.APIError.httpStatus(http.statusCode, body)
        }
    }
}
