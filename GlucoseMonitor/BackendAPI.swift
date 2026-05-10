import Foundation
import UIKit

/// iOS API layer: notes, COB, calculations, insulin, Nightscout, AI insights, nutrition, version.
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
        let photoUrl: String?
    }

    struct NoteInput: Encodable {
        let timestamp: String
        let carbs: Double
        let insulin: Double
        let meal: String
        let comment: String?
        let glucoseValue: Double?
        let absorptionMode: String?
    }

    struct UpdateNoteBody: Encodable {
        var timestamp: String?
        var carbs: Double?
        var insulin: Double?
        var meal: String?
        var comment: String?
        var glucoseValue: Double?
        var absorptionMode: String?
    }

    /// Matches Spring `@JsonFormat(pattern = "yyyy-MM-dd'T'HH:mm:ss")` on note DTOs (naive local wall time).
    static func formatNoteTimestampForRequest(_ date: Date) -> String {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = TimeZone.current
        f.dateFormat = "yyyy-MM-dd'T'HH:mm:ss"
        return f.string(from: date)
    }

    /// COB tuning; `carbRatio` is mmol/L glucose rise per **10 g** carbs (no insulin), matching backend `(COB_g / 10) * carbRatio`.
    struct COBSettings: Codable {
        var carbRatio: Double
        var isf: Double
        var carbHalfLife: Double
        var maxCOBDuration: Double
    }

    struct PredictionFactors: Decodable {
        let carbContribution: Double?
        let insulinContribution: Double?
        let baselineContribution: Double?
        let trendContribution: Double?
        let preBolusTimingContribution: Double?
        let avgBolusToMealMinutes: Double?
        let estimatedMealGi: Double?
        let estimatedMealGl: Double?
        let absorptionSpeedClass: String?
        let absorptionMode: String?
    }

    struct PredictionPathPoint: Decodable {
        let timestamp: Date
        let predictedGlucose: Double?
        let carbAbsorptionEffect: Double?
        let insulinActivityEffect: Double?
        let absorptionMode: String?

        enum CodingKeys: String, CodingKey {
            case timestamp, predictedGlucose, carbAbsorptionEffect, insulinActivityEffect, absorptionMode
        }

        init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            predictedGlucose = Self.decodeFlexibleDouble(c, key: .predictedGlucose)
            carbAbsorptionEffect = Self.decodeFlexibleDouble(c, key: .carbAbsorptionEffect)
            insulinActivityEffect = Self.decodeFlexibleDouble(c, key: .insulinActivityEffect)
            absorptionMode = try c.decodeIfPresent(String.self, forKey: .absorptionMode)

            if let s = try? c.decode(String.self, forKey: .timestamp) {
                timestamp = Self.parseBackendDate(s) ?? Date()
            } else {
                timestamp = Date()
            }
        }

        private static func decodeFlexibleDouble<K: CodingKey>(
            _ c: KeyedDecodingContainer<K>, key: K
        ) -> Double? {
            if let x = try? c.decodeIfPresent(Double.self, forKey: key) { return x }
            if let x = try? c.decodeIfPresent(Int.self, forKey: key) { return Double(x) }
            return nil
        }

        private static func parseBackendDate(_ s: String) -> Date? {
            let df = DateFormatter()
            df.locale = Locale(identifier: "en_US_POSIX")
            // Backend sends naive local time (no timezone suffix), so interpret
            // it in the device's current timezone — not UTC.
            df.timeZone = TimeZone.current
            for format in ["yyyy-MM-dd'T'HH:mm:ss", "yyyy-MM-dd'T'HH:mm:ss.SSS"] {
                df.dateFormat = format
                if let d = df.date(from: s) { return d }
            }
            // Fall back to ISO-8601 with explicit timezone (Z / ±HH:MM)
            let iso = ISO8601DateFormatter()
            iso.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
            if let d = iso.date(from: s) { return d }
            iso.formatOptions = [.withInternetDateTime]
            return iso.date(from: s)
        }
    }

    struct GlucoseCalculationsResponse: Decodable {
        let activeCarbsOnBoard: Double
        let activeInsulinOnBoard: Double
        let twoHourPrediction: Double
        let predictionTrend: String
        let confidence: Double
        let factors: PredictionFactors?
        let predictionPath: [PredictionPathPoint]?

        struct Envelope: Decodable {
            let backendMode: Bool?
            let data: GlucoseCalculationsResponse?
            let message: String?
        }

        enum CodingKeys: String, CodingKey {
            case activeCarbsOnBoard, activeInsulinOnBoard, twoHourPrediction, predictionTrend, confidence
            case factors, predictionPath
        }

        init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            activeCarbsOnBoard = Self.decodeFlexible(c, key: .activeCarbsOnBoard) ?? 0
            activeInsulinOnBoard = Self.decodeFlexible(c, key: .activeInsulinOnBoard) ?? 0
            twoHourPrediction = Self.decodeFlexible(c, key: .twoHourPrediction) ?? 0
            predictionTrend = try c.decodeIfPresent(String.self, forKey: .predictionTrend) ?? "stable"
            confidence = Self.decodeFlexible(c, key: .confidence) ?? 0
            factors = try? c.decode(PredictionFactors.self, forKey: .factors)
            predictionPath = try? c.decode([PredictionPathPoint].self, forKey: .predictionPath)
        }

        private static func decodeFlexible(
            _ c: KeyedDecodingContainer<CodingKeys>, key: CodingKeys
        ) -> Double? {
            if let x = try? c.decodeIfPresent(Double.self, forKey: key) { return x }
            if let x = try? c.decodeIfPresent(Int.self, forKey: key) { return Double(x) }
            return nil
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
        let direction: String?
        let type: String?

        enum CodingKeys: String, CodingKey {
            case id = "_id"
            case date
            case dateString
            case sgv, trend, direction, type
        }

        init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            id = try c.decodeIfPresent(String.self, forKey: .id)
            trend = try c.decodeIfPresent(Int.self, forKey: .trend)
            direction = try c.decodeIfPresent(String.self, forKey: .direction)
            type = try c.decodeIfPresent(String.self, forKey: .type)

            if let i = try? c.decodeIfPresent(Int.self, forKey: .sgv) {
                sgv = Double(i)
            } else {
                sgv = try c.decodeIfPresent(Double.self, forKey: .sgv)
            }

            if let ms = try? c.decodeIfPresent(Int64.self, forKey: .date) {
                timestamp = Date(timeIntervalSince1970: Double(ms) / 1000.0)
            } else if let ms = try? c.decodeIfPresent(Double.self, forKey: .date) {
                timestamp = Date(timeIntervalSince1970: ms / 1000.0)
            } else if let ds = try? c.decodeIfPresent(String.self, forKey: .dateString), !ds.isEmpty {
                timestamp = NightscoutEntry.parseNightscoutDateString(ds)
            } else {
                timestamp = nil
            }
        }

        func toLibreGlucoseCurrent() -> GlucoseMonitorAPI.LibreGlucoseCurrent {
            GlucoseMonitorAPI.LibreGlucoseCurrent(
                timestamp: timestamp,
                value: sgv,
                trend: trend,
                trendArrow: NightscoutEntry.directionArrow(direction),
                status: glucoseStatus(sgv, unit: "mg/dL"),
                unit: "mg/dL"
            )
        }

        static func directionArrow(_ direction: String?) -> String {
            guard let d = direction?.trimmingCharacters(in: .whitespacesAndNewlines), !d.isEmpty else {
                return "\u{2192}"
            }
            switch d {
            case "DoubleUp": return "\u{2191}\u{2191}"
            case "SingleUp": return "\u{2191}"
            case "FortyFiveUp": return "\u{2197}"
            case "Flat": return "\u{2192}"
            case "FortyFiveDown": return "\u{2198}"
            case "SingleDown": return "\u{2193}"
            case "DoubleDown": return "\u{2193}\u{2193}"
            case "NOT COMPUTABLE", "RATE OUT OF RANGE": return "\u{2192}"
            default: return "\u{2192}"
            }
        }

        private static func parseNightscoutDateString(_ s: String) -> Date? {
            let f1 = ISO8601DateFormatter()
            f1.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
            if let d = f1.date(from: s) { return d }
            let f2 = ISO8601DateFormatter()
            f2.formatOptions = [.withInternetDateTime]
            return f2.date(from: s)
        }
    }

    struct NightscoutConfig: Codable {
        var url: String
        var secret: String?
        var token: String?
    }

    struct AiRecommendation: Decodable {
        let code: String?
        let text: String?
        let priority: String?
    }

    struct AiAnalysisResult: Decodable {
        let summary: String?
        let recommendations: [AiRecommendation]?
        let disclaimer: String?
        let confidence: Double?
        let modelId: String?
        let latencyMs: Int64?
    }

    struct NutritionSnapshot: Decodable {
        let absorptionMode: String?
        let source: String?
        let confidence: Double?
        let totalCarbs: Double?
        let fiber: Double?
        let protein: Double?
        let fat: Double?
        let estimatedGi: Double?
        let glycemicLoad: Double?
        let absorptionSpeedClass: String?
        let normalizedFoods: [String]?
    }

    struct BackendVersionPayload: Decodable {
        let version: String?
        let apiVersion: String?
        let environment: String?
        let minIosVersion: String?
        let compatibleIosVersions: [String]?
        let status: String?
    }

    struct CompatibilityPayload: Decodable {
        let compatible: Bool?
        let meetsMinimumVersion: Bool?
        let recommendation: String?
        let backendVersion: String?
        let clientVersion: String?
    }

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
        req.setValue(TimeZone.current.identifier, forHTTPHeaderField: "X-Timezone")
        req.setValue("\(TimeZone.current.secondsFromGMT() / 60)", forHTTPHeaderField: "X-Timezone-Offset")
        req.setValue(ClientVersion.clientPlatform, forHTTPHeaderField: "X-Client-Platform")
        req.setValue(ClientVersion.resolvedSemanticVersion(), forHTTPHeaderField: "X-Client-Version")
        req.setValue(ClientVersion.apiVersion, forHTTPHeaderField: "X-API-Version")
        return req
    }

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

    // MARK: - Notes

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

    static func updateNote(id: String, body: UpdateNoteBody) async throws -> GlucoseNote {
        try await performWithRefresh {
            var req = try authorizedRequest(path: "/api/notes/\(id)", method: "PUT")
            req.httpBody = try JSONEncoder().encode(body)
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

    /// Crop `image` to a center square, compress to JPEG at 0.72 quality, upload as multipart/form-data.
    /// Returns the updated note (with `photoUrl` set by the backend).
    static func uploadNotePhoto(noteId: String, image: UIImage) async throws -> GlucoseNote {
        let squareImage = cropToSquare(image)
        guard let jpeg = squareImage.jpegData(compressionQuality: 0.72) else {
            throw GlucoseMonitorAPI.APIError.decoding(
                NSError(domain: "BackendAPI", code: 0,
                        userInfo: [NSLocalizedDescriptionKey: "Could not compress image"])
            )
        }

        return try await performWithRefresh {
            var req = try authorizedRequest(path: "/api/notes/\(noteId)/photo", method: "POST")
            let boundary = "Boundary-\(UUID().uuidString)"
            req.setValue("multipart/form-data; boundary=\(boundary)", forHTTPHeaderField: "Content-Type")

            var body = Data()
            body.append("--\(boundary)\r\n".data(using: .utf8)!)
            body.append("Content-Disposition: form-data; name=\"photo\"; filename=\"meal.jpg\"\r\n".data(using: .utf8)!)
            body.append("Content-Type: image/jpeg\r\n\r\n".data(using: .utf8)!)
            body.append(jpeg)
            body.append("\r\n--\(boundary)--\r\n".data(using: .utf8)!)
            req.httpBody = body

            let (data, resp) = try await URLSession.shared.data(for: req)
            try checkStatus(resp, data: data)
            return try GlucoseMonitorAPI.jsonDecoder().decode(GlucoseNote.self, from: data)
        }
    }

    private static func cropToSquare(_ image: UIImage) -> UIImage {
        let side = min(image.size.width, image.size.height)
        let origin = CGPoint(
            x: (image.size.width  - side) / 2,
            y: (image.size.height - side) / 2
        )
        let cropRect = CGRect(origin: origin, size: CGSize(width: side, height: side))
        let scale = image.scale
        let scaledRect = CGRect(
            x: cropRect.origin.x    * scale,
            y: cropRect.origin.y    * scale,
            width: cropRect.width   * scale,
            height: cropRect.height * scale
        )
        if let cgImg = image.cgImage?.cropping(to: scaledRect) {
            return UIImage(cgImage: cgImg, scale: scale, orientation: image.imageOrientation)
        }
        return image
    }

    // MARK: - COB Settings

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

    // MARK: - Glucose calculations

    static func fetchGlucoseCalculations(currentGlucose: Double) async throws -> GlucoseCalculationsResponse {
        try await performWithRefresh {
            // Trailing slash matches web axios baseURL + post('/') and Spring `@PostMapping("/")`.
            var req = try authorizedRequest(path: "/api/glucose-calculations/", method: "POST")

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
            // Same as web `getClientTimeInfo()` / note payloads: naive local wall time, not UTC ISO8601 with Z.
            // Backend compares this to note timestamps (also local wall time) for COB windows and decay.
            let body = Body(
                currentGlucose: currentGlucose,
                includePredictionFactors: true,
                clientTimeInfo: TimeInfo(
                    timestamp: formatNoteTimestampForRequest(Date()),
                    timezone: tz.identifier,
                    timezoneOffset: -tz.secondsFromGMT() / 60
                )
            )
            req.httpBody = try JSONEncoder().encode(body)

            let (data, resp) = try await URLSession.shared.data(for: req)
            try checkStatus(resp, data: data)

            let decoder = JSONDecoder()
            let envelope = try decoder.decode(GlucoseCalculationsResponse.Envelope.self, from: data)
            guard let result = envelope.data else {
                throw GlucoseMonitorAPI.APIError.decoding(
                    NSError(
                        domain: "BackendAPI", code: 0,
                        userInfo: [NSLocalizedDescriptionKey: envelope.message ?? "No calculation data returned"]
                    )
                )
            }
            return result
        }
    }

    // MARK: - Insulin preferences

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

    // MARK: - Nightscout

    /// Live Nightscout proxy (`useStored=false`) or DB-cached entries from last successful sync (`useStored=true`).
    static func fetchNightscoutEntries(count: Int = 24, useStored: Bool = false) async throws -> [NightscoutEntry] {
        try await performWithRefresh {
            let stored = useStored ? "true" : "false"
            let req = try authorizedRequest(path: "/api/nightscout/entries?count=\(count)&useStored=\(stored)")
            let (data, resp) = try await URLSession.shared.data(for: req)
            try checkStatus(resp, data: data)
            let decoder = JSONDecoder()
            return try decoder.decode([NightscoutEntry].self, from: data)
        }
    }

    /// Stored chart points written by the backend when a live sync succeeds (`EnhancedNightscoutService` strategy 3).
    static func fetchNightscoutChartData(count: Int = 100) async throws -> [NightscoutEntry] {
        try await performWithRefresh {
            let req = try authorizedRequest(path: "/api/nightscout/chart-data?count=\(count)")
            let (data, resp) = try await URLSession.shared.data(for: req)
            try checkStatus(resp, data: data)
            return try JSONDecoder().decode([NightscoutEntry].self, from: data)
        }
    }

    /// Matches web `EnhancedNightscoutService.getGlucoseEntries`: live -> `useStored` -> chart-data.
    static func fetchNightscoutEntriesWithFallbacks(count: Int) async throws -> [NightscoutEntry] {
        var firstError: Error?

        do {
            let fresh = try await fetchNightscoutEntries(count: count, useStored: false)
            if !fresh.isEmpty { return fresh }
        } catch {
            firstError = error
        }

        do {
            let cached = try await fetchNightscoutEntries(count: count, useStored: true)
            if !cached.isEmpty { return cached }
        } catch {
            if firstError == nil { firstError = error }
        }

        do {
            let chart = try await fetchNightscoutChartData(count: count)
            if !chart.isEmpty { return chart }
        } catch {
            if firstError == nil { firstError = error }
        }

        throw firstError ?? GlucoseMonitorAPI.APIError.httpStatus(
            400,
            "No glucose data (live or cached). Open Settings, check Nightscout URL and API secret, then Save."
        )
    }

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

    // MARK: - AI insights

    static func fetchAiRetrospective(windowHours: Int = 12) async throws -> AiAnalysisResult {
        try await performWithRefresh {
            var req = try authorizedRequest(path: "/api/ai-insights/retrospective", method: "POST")
            struct Body: Encodable { let windowHours: Int }
            req.httpBody = try JSONEncoder().encode(Body(windowHours: windowHours))
            let (data, resp) = try await URLSession.shared.data(for: req)
            try checkStatus(resp, data: data)
            let decoder = JSONDecoder()
            return try decoder.decode(AiAnalysisResult.self, from: data)
        }
    }

    /// Streams markdown tokens from the backend NDJSON endpoint.
    /// Calls `onToken` on the main actor for each `{"type":"token","token":"..."}` line.
    /// Returns when the `{"type":"done"}` event is received or the stream ends.
    static func streamAiRetrospective(
        windowHours: Int = 12,
        onToken: @MainActor @escaping (String) -> Void
    ) async throws {
        struct Body: Encodable { let windowHours: Int }
        struct StreamEvent: Decodable {
            let type: String
            let token: String?
        }

        var req = try authorizedRequest(path: "/api/ai-insights/retrospective/stream", method: "POST")
        req.httpBody = try JSONEncoder().encode(Body(windowHours: windowHours))

        let (bytes, resp) = try await URLSession.shared.bytes(for: req)
        try checkStatus(resp, data: Data())

        for try await line in bytes.lines {
            guard !line.isEmpty,
                  let data = line.data(using: .utf8),
                  let event = try? JSONDecoder().decode(StreamEvent.self, from: data)
            else { continue }

            if event.type == "done" { break }
            if event.type == "token", let tok = event.token {
                await onToken(tok)
            }
        }
    }

    // MARK: - Nutrition

    static func analyzeNutrition(ingredientsText: String, fallbackCarbs: Double?) async throws -> NutritionSnapshot {
        try await performWithRefresh {
            var req = try authorizedRequest(path: "/api/nutrition/analyze", method: "POST")
            struct Body: Encodable {
                let ingredientsText: String
                let fallbackCarbs: Double?
            }
            req.httpBody = try JSONEncoder().encode(Body(ingredientsText: ingredientsText, fallbackCarbs: fallbackCarbs))
            let (data, resp) = try await URLSession.shared.data(for: req)
            try checkStatus(resp, data: data)
            return try JSONDecoder().decode(NutritionSnapshot.self, from: data)
        }
    }

    // MARK: - Version

    static func fetchBackendVersion() async throws -> BackendVersionPayload {
        try await performWithRefresh {
            let req = try authorizedRequest(path: "/api/version/")
            let (data, resp) = try await URLSession.shared.data(for: req)
            try checkStatus(resp, data: data)
            return try JSONDecoder().decode(BackendVersionPayload.self, from: data)
        }
    }

    static func checkCompatibility() async throws -> CompatibilityPayload {
        try await performWithRefresh {
            var req = try authorizedRequest(path: "/api/version/check-compatibility", method: "POST")
            struct Body: Encodable {
                let clientType: String
                let clientVersion: String
            }
            let body = Body(clientType: ClientVersion.clientPlatform, clientVersion: ClientVersion.resolvedSemanticVersion())
            req.httpBody = try JSONEncoder().encode(body)
            let (data, resp) = try await URLSession.shared.data(for: req)
            try checkStatus(resp, data: data)
            return try JSONDecoder().decode(CompatibilityPayload.self, from: data)
        }
    }

    // MARK: - Glucose status (Nightscout mg/dL)

    static func glucoseStatus(_ value: Double?, unit: String?) -> String {
        guard let v = value else { return "unknown" }
        let mgdl = unit?.lowercased().contains("mmol") == true ? v * 18.018 : v
        switch mgdl {
        case ..<54: return "critical"
        case ..<70: return "low"
        case ...180: return "normal"
        default: return "high"
        }
    }
}
