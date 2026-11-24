import Foundation

/// `GET /api/watch/glance` with the watch's own session.
enum GlanceClient {

    static func fetch() async throws -> WatchGlance {
        do {
            return try await fetchOnce()
        } catch GlucoseMonitorAPI.APIError.httpStatus(401, _) {
            do {
                try await GlucoseMonitorAPI.refreshToken()
            } catch GlucoseMonitorAPI.APIError.httpStatus(let code, _) where code == 401 || code == 403 {
                // The refresh token itself was rejected: the receiver asks the phone for a new session.
                GlucoseMonitorAPI.clearSession(notify: true)
                throw GlucoseMonitorAPI.APIError.missingToken
            }
            return try await fetchOnce()
        }
    }

    private static func fetchOnce() async throws -> WatchGlance {
        guard let token = GlucoseMonitorAPI.storedAccessToken(), !token.isEmpty else {
            throw GlucoseMonitorAPI.APIError.missingToken
        }
        var components = URLComponents(string: GlucoseMonitorAPI.effectiveBackendBaseURL() + "/api/watch/glance")
        components?.queryItems = [URLQueryItem(name: "tz", value: TimeZone.current.identifier)]
        guard let url = components?.url else { throw GlucoseMonitorAPI.APIError.invalidURL }
        var req = URLRequest(url: url)
        req.httpMethod = "GET"
        req.timeoutInterval = 20
        req.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        let (data, resp) = try await URLSession.shared.data(for: req)
        guard let http = resp as? HTTPURLResponse else { throw GlucoseMonitorAPI.APIError.httpStatus(-1, nil) }
        guard (200 ..< 300).contains(http.statusCode) else {
            throw GlucoseMonitorAPI.APIError.httpStatus(http.statusCode, String(data: data, encoding: .utf8))
        }
        do {
            return try JSONDecoder().decode(WatchGlance.self, from: data)
        } catch {
            throw GlucoseMonitorAPI.APIError.decoding(error)
        }
    }
}
