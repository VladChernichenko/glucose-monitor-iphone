import Foundation

/// iOS-only API layer — Notes, COB Settings, Glucose Calculations, Insulin Preferences, Nightscout.
/// Mirrors the logic in the web frontend's service layer (authService, backendNotesApi,
/// cobSettingsApi, glucoseCalculationsApi, insulinPreferencesApi, nightscout services).
enum BackendAPI {

    // MARK: - Models

    struct GlucoseNote: Decodable, Identifiable {
        let id: String
        let timestamp: Date?
        let carbs: Double
        let insulin: Double
        let meal: String
        let comment: String?
        let glucoseValue: Double?
        let absorptionMode: String?
    }

    struct NoteInput: Encodable {
        let timestamp: String   // ISO8601
        let carbs: Double
        let insulin: Double
        let meal: String
        let comment: String?
        let glucoseValue: Double?
        let absorptionMode: String?
    }

    struct COBSettings: Codable {
        var carbRatio: Double
        var isf: Double
        var carbHalfLife: Double
        var maxCOBDuration: Double
    }

    struct GlucoseCalculationsResponse: Decodable {
        let activeCarbsOnBoard: Double
        let activeInsulinOnBoard: Double
        let twoHourPrediction: Double
        let predictionTrend: String   // "rising" | "falling" | "stable"
        let confidence: Double

        // The backend wraps the real payload in { backendMode, data }
        struct Envelope: Decodable {
            let backendMode: Bool?
            let data: GlucoseCalculationsResponse?
            let message: String?
        }
    }

    struct InsulinCatalogEntry: Decodable, Identifiable {
        var id: String { code }
        let code: String
        let category: String
        let displayName: String
        let peakMinutes: Int?
        let diaHours: Double
        let halfLifeMinutes: Double
        let onsetMinutes: Int?
        let description: String?
    }

    struct UserInsulinPreferences: Decodable {
        let rapidInsulinCode: String
        let longActingInsulinCode: String
        let rapidInsulin: InsulinCatalogEntry
        let longActingInsulin: InsulinCatalogEntry
    }

    struct NightscoutEntry: Decodable {
        let id: String?
        let timestamp: Date?
        let sgv: Double?
        let trend: Int?
        let trendArrow: String?

        private enum CodingKeys: String, CodingKey {
            case id = "_id"
            case timestamp = "dateString"
            case sgv, trend, trendArrow
        }

        /// Converts a Nightscout entry to the common glucose display model.
        func toLibreGlucoseCurrent() -> GlucoseMonitorAPI.LibreGlucoseCurrent {
            let arrow: String
            switch trend {
            case 1: arrow = "↑↑"
            case 2: arrow = "↑"
            case 3: arrow = "↗"
            case 4: arrow = "→"
            case 5: arrow = "↘"
            case 6: arrow = "↓"
            case 7: arrow = "↓↓"
            default: arrow = "→"
            }
            return GlucoseMonitorAPI.LibreGlucoseCurrent(
                timestamp: timestamp,
                value: sgv,
                trend: trend,
                trendArrow: trendArrow ?? arrow,
                status: glucoseStatus(sgv, unit: "mg/dL"),
                unit: "mg/dL"
            )
        }
    }

    struct NightscoutConfig: Codable {
        var url: String
        var secret: String?
        var token: String?
    }

    /// Matches `UserDataSourceConfigDto` / `DataSourceConfigRequestDto` (Nightscout fields).
    private struct UserDataSourceNightscoutResponse: Decodable {
        let nightscoutUrl: String?
        let nightscoutApiSecret: String?
        let nightscoutApiToken: String?
    }

    private struct NightscoutConfigSaveBody: Encodable {
        let dataSource: String
        let nightscoutUrl: String
        let nightscoutApiSecret: String?
        let nightscoutApiToken: String?
        let isActive: Bool
    }

    // MARK: - Request helpers

    /// Builds an authenticated URLRequest for the stored backend URL.
    private static func authorizedRequest(path: String, method: String = "GET") throws -> URLRequest {
        let ud = GlucoseMonitorAPI.sharedDefaults()
        let base = GlucoseMonitorAPI.effectiveBackendBaseURL()

        guard let token = ud.string(forKey: GlucoseMonitorAPI.StorageKey.accessToken), !token.isEmpty else {
            throw GlucoseMonitorAPI.APIError.missingToken
        }
        guard let url = URL(string: base + path) else { throw GlucoseMonitorAPI.APIError.invalidURL }

        var req = URLRequest(url: url)
        req.httpMethod = method
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        // Mirror the web frontend's timezone headers
        req.setValue(TimeZone.current.identifier, forHTTPHeaderField: "X-Timezone")
        req.setValue("\(TimeZone.current.secondsFromGMT() / 60)", forHTTPHeaderField: "X-Timezone-Offset")
        return req
    }

    /// Retries `work` once after a successful token refresh on 401.
    private static func performWithRefresh<T>(_ work: () async throws -> T) async throws -> T {
        do {
            return try await work()
        } catch let err as GlucoseMonitorAPI.APIError {
            if case .httpStatus(401, _) = err {
                try await GlucoseMonitorAPI.refreshToken()
                return try await work()
            }
            throw err
        }
    }

    private static func checkStatus(_ response: URLResponse, data: Data) throws {
        guard let http = response as? HTTPURLResponse else {
            throw GlucoseMonitorAPI.APIError.httpStatus(-1, nil)
        }
        guard (200 ..< 300).contains(http.statusCode) else {
            throw GlucoseMonitorAPI.APIError.httpStatus(http.statusCode, String(data: data, encoding: .utf8))
        }
    }

    // MARK: - Notes  (mirrors backendNotesApi.ts)

    static func fetchNotes() async throws -> [GlucoseNote] {
        try await performWithRefresh {
            let req = try authorizedRequest(path: "/api/notes/")
            let (data, resp) = try await URLSession.shared.data(for: req)
            try checkStatus(resp, data: data)
            return try GlucoseMonitorAPI.jsonDecoder().decode([GlucoseNote].self, from: data)
        }
    }

    static func createNote(_ input: NoteInput) async throws -> GlucoseNote {
        try await performWithRefresh {
            var req = try authorizedRequest(path: "/api/notes/", method: "POST")
            req.httpBody = try JSONEncoder().encode(input)
            let (data, resp) = try await URLSession.shared.data(for: req)
            try checkStatus(resp, data: data)
            return try GlucoseMonitorAPI.jsonDecoder().decode(GlucoseNote.self, from: data)
        }
    }

    static func deleteNote(id: String) async throws {
        try await performWithRefresh {
            let req = try authorizedRequest(path: "/api/notes/\(id)", method: "DELETE")
            let (data, resp) = try await URLSession.shared.data(for: req)
            try checkStatus(resp, data: data)
        }
    }

    // MARK: - COB Settings  (mirrors cobSettingsApi.ts)

    static func fetchCOBSettings() async throws -> COBSettings {
        try await performWithRefresh {
            let req = try authorizedRequest(path: "/api/cob-settings/")
            let (data, resp) = try await URLSession.shared.data(for: req)
            try checkStatus(resp, data: data)
            return try JSONDecoder().decode(COBSettings.self, from: data)
        }
    }

    static func saveCOBSettings(_ settings: COBSettings) async throws -> COBSettings {
        try await performWithRefresh {
            var req = try authorizedRequest(path: "/api/cob-settings/", method: "POST")
            req.httpBody = try JSONEncoder().encode(settings)
            let (data, resp) = try await URLSession.shared.data(for: req)
            try checkStatus(resp, data: data)
            return try JSONDecoder().decode(COBSettings.self, from: data)
        }
    }

    // MARK: - Glucose Calculations  (mirrors glucoseCalculationsApi.ts)

    static func fetchGlucoseCalculations(currentGlucose: Double) async throws -> GlucoseCalculationsResponse {
        try await performWithRefresh {
            var req = try authorizedRequest(path: "/api/glucose-calculations", method: "POST")

            struct TimeInfo: Encodable {
                let timestamp: String
                let timezone: String
                let timezoneOffset: Int
            }
            struct Body: Encodable {
                let currentGlucose: Double
                let includePredictionFactors: Bool
                let clientTimeInfo: TimeInfo
            }

            let tz = TimeZone.current
            let body = Body(
                currentGlucose: currentGlucose,
                includePredictionFactors: true,
                clientTimeInfo: TimeInfo(
                    timestamp: ISO8601DateFormatter().string(from: Date()),
                    timezone: tz.identifier,
                    timezoneOffset: tz.secondsFromGMT() / 60
                )
            )
            req.httpBody = try JSONEncoder().encode(body)

            let (data, resp) = try await URLSession.shared.data(for: req)
            try checkStatus(resp, data: data)

            let envelope = try JSONDecoder().decode(GlucoseCalculationsResponse.Envelope.self, from: data)
            guard let result = envelope.data else {
                throw GlucoseMonitorAPI.APIError.decoding(
                    NSError(domain: "BackendAPI", code: 0,
                            userInfo: [NSLocalizedDescriptionKey: envelope.message ?? "No calculation data returned"])
                )
            }
            return result
        }
    }

    // MARK: - Insulin Preferences  (mirrors insulinPreferencesApi.ts)

    static func fetchInsulinCatalog(category: String? = nil) async throws -> [InsulinCatalogEntry] {
        try await performWithRefresh {
            let path = category.map { "/api/insulin-catalog?category=\($0)" } ?? "/api/insulin-catalog"
            let req = try authorizedRequest(path: path)
            let (data, resp) = try await URLSession.shared.data(for: req)
            try checkStatus(resp, data: data)
            return try JSONDecoder().decode([InsulinCatalogEntry].self, from: data)
        }
    }

    static func fetchInsulinPreferences() async throws -> UserInsulinPreferences {
        try await performWithRefresh {
            let req = try authorizedRequest(path: "/api/user/insulin-preferences")
            let (data, resp) = try await URLSession.shared.data(for: req)
            try checkStatus(resp, data: data)
            return try JSONDecoder().decode(UserInsulinPreferences.self, from: data)
        }
    }

    static func saveInsulinPreferences(rapidCode: String, longActingCode: String) async throws -> UserInsulinPreferences {
        try await performWithRefresh {
            var req = try authorizedRequest(path: "/api/user/insulin-preferences", method: "PUT")
            struct Body: Encodable { let rapidInsulinCode: String; let longActingInsulinCode: String }
            req.httpBody = try JSONEncoder().encode(Body(rapidInsulinCode: rapidCode, longActingInsulinCode: longActingCode))
            let (data, resp) = try await URLSession.shared.data(for: req)
            try checkStatus(resp, data: data)
            return try JSONDecoder().decode(UserInsulinPreferences.self, from: data)
        }
    }

    // MARK: - Nightscout  (mirrors enhancedNightscoutService.ts / nightscoutProxyService.ts)

    static func fetchNightscoutEntries(count: Int = 24) async throws -> [NightscoutEntry] {
        try await performWithRefresh {
            let req = try authorizedRequest(path: "/api/nightscout/entries?count=\(count)")
            let (data, resp) = try await URLSession.shared.data(for: req)
            try checkStatus(resp, data: data)
            return try GlucoseMonitorAPI.jsonDecoder().decode([NightscoutEntry].self, from: data)
        }
    }

    /// Active Nightscout config from `GET /api/user/data-source-config/active/NIGHTSCOUT`.
    static func fetchNightscoutConfig() async throws -> NightscoutConfig? {
        try await performWithRefresh {
            let req = try authorizedRequest(path: "/api/user/data-source-config/active/NIGHTSCOUT")
            let (data, resp) = try await URLSession.shared.data(for: req)
            guard let http = resp as? HTTPURLResponse else {
                throw GlucoseMonitorAPI.APIError.httpStatus(-1, nil)
            }
            if http.statusCode == 404 { return nil }
            try checkStatus(resp, data: data)
            let dto = try JSONDecoder().decode(UserDataSourceNightscoutResponse.self, from: data)
            guard let url = dto.nightscoutUrl?.trimmingCharacters(in: .whitespacesAndNewlines), !url.isEmpty else {
                return nil
            }
            return NightscoutConfig(
                url: url,
                secret: dto.nightscoutApiSecret,
                token: dto.nightscoutApiToken
            )
        }
    }

    /// Persists Nightscout URL/secret via `POST /api/user/data-source-config` (same as web `userDataSourceConfigApi`).
    static func saveNightscoutConfig(_ config: NightscoutConfig) async throws {
        try await performWithRefresh {
            var req = try authorizedRequest(path: "/api/user/data-source-config", method: "POST")
            let body = NightscoutConfigSaveBody(
                dataSource: "NIGHTSCOUT",
                nightscoutUrl: config.url.trimmingCharacters(in: .whitespacesAndNewlines),
                nightscoutApiSecret: config.secret?.isEmpty == true ? nil : config.secret,
                nightscoutApiToken: config.token?.isEmpty == true ? nil : config.token,
                isActive: true
            )
            req.httpBody = try JSONEncoder().encode(body)
            let (data, resp) = try await URLSession.shared.data(for: req)
            try checkStatus(resp, data: data)
        }
    }

    // MARK: - Private utilities

    /// Derives a status string from a glucose value — mirrors the web frontend's status logic.
    private static func glucoseStatus(_ value: Double?, unit: String?) -> String {
        guard let v = value else { return "unknown" }
        let mgdl = unit?.lowercased().contains("mmol") == true ? v * 18.018 : v
        switch mgdl {
        case ..<54:  return "critical"
        case ..<70:  return "low"
        case ...180: return "normal"
        default:     return "high"
        }
    }
}