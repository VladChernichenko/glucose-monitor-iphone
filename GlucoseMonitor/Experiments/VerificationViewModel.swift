import Foundation
import SwiftUI

@MainActor
final class VerificationViewModel: ObservableObject {

    @Published var summary: VerificationSummary?
    @Published var events: [VerificationEventModel] = []
    @Published var isLoading = false
    @Published var isAccepting = false
    @Published var error: String?
    @Published var accepted = false

    private let decoder: JSONDecoder = {
        let d = JSONDecoder()
        d.keyDecodingStrategy = .convertFromSnakeCase
        return d
    }()

    // MARK: - Load

    func load() async {
        isLoading = true
        error = nil
        defer { isLoading = false }
        do {
            summary = try await fetchSummary()
            events  = try await fetchEvents()
        } catch {
            self.error = error.localizedDescription
        }
    }

    // MARK: - Accept suggestion

    func acceptSuggestion() async {
        isAccepting = true
        defer { isAccepting = false }
        do {
            try await callAccept()
            accepted = true
            await load()
        } catch {
            self.error = error.localizedDescription
        }
    }

    // MARK: - API calls

    private func fetchSummary() async throws -> VerificationSummary {
        let req = try buildRequest("/api/experiments/verification/summary", method: "GET")
        let (data, resp) = try await URLSession.shared.data(for: req)
        try checkStatus(resp, data: data)
        return try decoder.decode(VerificationSummary.self, from: data)
    }

    private func fetchEvents() async throws -> [VerificationEventModel] {
        let req = try buildRequest("/api/experiments/verification/events", method: "GET")
        let (data, resp) = try await URLSession.shared.data(for: req)
        try checkStatus(resp, data: data)
        return try decoder.decode([VerificationEventModel].self, from: data)
    }

    private func callAccept() async throws {
        var req = try buildRequest("/api/experiments/verification/accept-suggestion", method: "POST")
        req.httpBody = Data()
        let (data, resp) = try await URLSession.shared.data(for: req)
        try checkStatus(resp, data: data)
    }

    private func buildRequest(_ path: String, method: String) throws -> URLRequest {
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
        req.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        return req
    }

    private func checkStatus(_ response: URLResponse, data: Data) throws {
        guard let http = response as? HTTPURLResponse,
              (200..<300).contains(http.statusCode) else {
            let body = String(data: data, encoding: .utf8) ?? ""
            let code = (response as? HTTPURLResponse)?.statusCode ?? 0
            throw GlucoseMonitorAPI.APIError.httpStatus(code, body)
        }
    }

    // MARK: - Computed

    var completedEvents: [VerificationEventModel] {
        events.filter { $0.status == "COMPLETED" }
    }
}
