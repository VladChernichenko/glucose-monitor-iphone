import Foundation
import UIKit

/// iOS API layer: notes, COB, calculations, insulin, Nightscout, AI insights, nutrition, version.
enum BackendAPI {

    // MARK: - Models

    /// Note category discriminator (mirrors backend `Note.type`).
    enum NoteType {
        static let normal = "normal"
        static let longActing = "long_acting"
    }

    struct GlucoseNote: Decodable, Identifiable {
        let id: String
        let timestamp: Date?
        let carbs: Double
        let insulin: Double
        let meal: String
        let comment: String?
        let glucoseValue: Double?
        let absorptionMode: String?
        /// Note category: "normal" (default) or "long_acting". Nil for legacy responses.
        var type: String? = nil
        let photoUrl: String?

        /// True when this note records a long-acting (basal) dose — not a rapid-acting bolus.
        var isLongActing: Bool { type == NoteType.longActing }
    }

    struct NoteInput: Encodable {
        let timestamp: String
        let carbs: Double
        let insulin: Double
        let meal: String
        let comment: String?
        let glucoseValue: Double?
        let absorptionMode: String?
        /// Serialised NutritionSnapshot JSON produced by the Nutrition analyser.
        /// When set, the backend stores it directly and skips server-side re-enrichment,
        /// preserving `suggestedDurationHours` so 8 h HFHP meals get the correct forecast.
        let nutritionProfile: String?
        /// Note category: nil → backend defaults to "normal"; "long_acting" for basal doses.
        var type: String? = nil
    }

    struct UpdateNoteBody: Encodable {
        var timestamp: String?
        var carbs: Double?
        var insulin: Double?
        var meal: String?
        var comment: String?
        var glucoseValue: Double?
        var absorptionMode: String?
        var type: String?
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
        let fourHourPrediction: Double?
        /// Non-nil only when the HFHP / Dual-Wave path extends beyond 4 h (≥ 8 h window).
        let eightHourPrediction: Double?
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
            case activeCarbsOnBoard, activeInsulinOnBoard, twoHourPrediction, fourHourPrediction
            case eightHourPrediction
            case predictionTrend, confidence, factors, predictionPath
        }

        init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            activeCarbsOnBoard = Self.decodeFlexible(c, key: .activeCarbsOnBoard) ?? 0
            activeInsulinOnBoard = Self.decodeFlexible(c, key: .activeInsulinOnBoard) ?? 0
            twoHourPrediction = Self.decodeFlexible(c, key: .twoHourPrediction) ?? 0
            fourHourPrediction = Self.decodeFlexible(c, key: .fourHourPrediction)
            eightHourPrediction = Self.decodeFlexible(c, key: .eightHourPrediction)
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
        /// Optional daily long-acting injection time as "HH:mm" (nil when unset).
        let longActingInjectionTime: String?
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
        let foodMassBreakdown: [FoodMassBreakdown]?
        // Glycemic pattern fields
        let patternName: String?
        let bolusStrategy: String?
        let suggestedDurationHours: Double?
        let mealSequencingPriority: Int?
        let curveDescription: String?
        let preBolusPauseMinutes: Int?

        struct FoodMassBreakdown: Decodable, Identifiable {
            // I2 fix: stored property so id is stable across accesses even when label is nil.
            let id: String
            let label: String?
            let massG: Double?
            let carbs: Double?
            let fat: Double?
            let protein: Double?
            let fiber: Double?
            let gi: Double?
            let offProductName: String?
            let confidence: Double?

            private enum CodingKeys: String, CodingKey {
                case label, massG, carbs, fat, protein, fiber, gi, offProductName, confidence
            }

            init(from decoder: Decoder) throws {
                let c = try decoder.container(keyedBy: CodingKeys.self)
                label         = try c.decodeIfPresent(String.self,  forKey: .label)
                massG         = try c.decodeIfPresent(Double.self,  forKey: .massG)
                carbs         = try c.decodeIfPresent(Double.self,  forKey: .carbs)
                fat           = try c.decodeIfPresent(Double.self,  forKey: .fat)
                protein       = try c.decodeIfPresent(Double.self,  forKey: .protein)
                fiber         = try c.decodeIfPresent(Double.self,  forKey: .fiber)
                gi            = try c.decodeIfPresent(Double.self,  forKey: .gi)
                offProductName = try c.decodeIfPresent(String.self, forKey: .offProductName)
                confidence    = try c.decodeIfPresent(Double.self,  forKey: .confidence)
                // Assign a stable id once at decode time.
                id = label ?? UUID().uuidString
            }
        }
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

    private static let photoAnalysisSession: URLSession = {
        let c = URLSessionConfiguration.default
        c.timeoutIntervalForRequest = 300
        c.timeoutIntervalForResource = 300
        return URLSession(configuration: c)
    }()

    private static func authorizedRequest(path: String, method: String = "GET") throws -> URLRequest {
        let ud = GlucoseMonitorAPI.sharedDefaults()
        let base = GlucoseMonitorAPI.effectiveBackendBaseURL()

        guard let token = GlucoseMonitorAPI.storedAccessToken(), !token.isEmpty else {
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
                do {
                    try await GlucoseMonitorAPI.refreshToken()
                } catch {
                    // refresh failed — the refresh token itself is expired/revoked.
                    // Keeping the dead tokens in the Keychain just repeats this dance
                    // forever; clear them so the UI can prompt re-login.
                    GlucoseMonitorAPI.clearSession()
                    throw err
                }
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

    private static func resizeImage(_ image: UIImage, maxSide: CGFloat) -> UIImage {
        let side = max(image.size.width, image.size.height)
        guard side > maxSide else { return image }
        let scale = maxSide / side
        let newSize = CGSize(width: image.size.width * scale, height: image.size.height * scale)
        let renderer = UIGraphicsImageRenderer(size: newSize)
        return renderer.image { _ in image.draw(in: CGRect(origin: .zero, size: newSize)) }
    }

    /// Tries decreasing JPEG quality until the data fits under 1 MB (LogMeal's hard limit).
    private static func compressUnder1MB(_ image: UIImage) -> Data? {
        let limit = 1_000_000
        for quality in [0.6, 0.5, 0.4, 0.3] {
            if let data = image.jpegData(compressionQuality: quality), data.count < limit {
                return data
            }
        }
        return image.jpegData(compressionQuality: 0.2)
    }

    // MARK: - ISF meal-window profile

    /// One bucket of the per-user observational ISF profile, mirroring backend `IsfMealWindowDTO`.
    /// `isfMmolPerU` is nil when the bucket has < 7 weighted samples — the chart renders that as
    /// a gap with a "Run ISF experiment at this hour" CTA.
    struct IsfMealWindow: Decodable, Identifiable {
        let mealWindow: String       // "BREAKFAST" | "LUNCH" | "DINNER"
        let startHour: Int           // inclusive
        let endHour: Int             // exclusive
        let isfMmolPerU: Double?
        let weightedSamples: Double?
        let rawSampleCount: Int?
        let hasData: Bool
        let lastUpdated: Date?

        var id: String { mealWindow }

        var displayName: String {
            switch mealWindow {
            case "BREAKFAST": return "Breakfast"
            case "LUNCH":     return "Lunch"
            case "DINNER":    return "Dinner"
            default:          return mealWindow.capitalized
            }
        }

        /// e.g. "05:00 – 11:00". Used as the x-axis label.
        var rangeLabel: String {
            String(format: "%02d:00 – %02d:00", startHour, endHour)
        }
    }

    struct IsfMealWindowProfile: Decodable {
        let windows: [IsfMealWindow]
        let minWeightedSamples: Double
        let historyDays: Int
    }

    static func fetchIsfMealWindows() async throws -> IsfMealWindowProfile {
        try await performWithRefresh {
            let req = try authorizedRequest(path: "/api/isf/meal-windows")
            let (data, resp) = try await URLSession.shared.data(for: req)
            try checkStatus(resp, data: data)
            return try GlucoseMonitorAPI.jsonDecoder().decode(IsfMealWindowProfile.self, from: data)
        }
    }

    /// Forces a recompute from the last 14 days. Backed by the daily scheduler too; this is the
    /// "Refresh now" button.
    static func recomputeIsfMealWindows() async throws -> IsfMealWindowProfile {
        try await performWithRefresh {
            let req = try authorizedRequest(path: "/api/isf/meal-windows/recompute", method: "POST")
            let (data, resp) = try await URLSession.shared.data(for: req)
            try checkStatus(resp, data: data)
            return try GlucoseMonitorAPI.jsonDecoder().decode(IsfMealWindowProfile.self, from: data)
        }
    }

    // MARK: - COB Settings

    static func fetchCOBSettings() async throws -> COBSettings {
        try await performWithRefresh {
            let req = try authorizedRequest(path: "/api/cob-settings/")
            let (data, resp) = try await URLSession.shared.data(for: req)
            try checkStatus(resp, data: data)
            return try GlucoseMonitorAPI.jsonDecoder().decode(COBSettings.self, from: data)
        }
    }

    static func saveCOBSettings(_ settings: COBSettings) async throws -> COBSettings {
        try await performWithRefresh {
            var req = try authorizedRequest(path: "/api/cob-settings/", method: "POST")
            req.httpBody = try JSONEncoder().encode(settings)
            let (data, resp) = try await URLSession.shared.data(for: req)
            try checkStatus(resp, data: data)
            return try GlucoseMonitorAPI.jsonDecoder().decode(COBSettings.self, from: data)
        }
    }

    // MARK: - Glucose calculations

    /// A single prospective meal event (analysed but not yet saved to notes).
    /// Sent to the backend so COB/IOB can include the in-progress meal in the prediction.
    struct ProspectiveNote: Encodable {
        let carbs: Double?
        let insulin: Double?
        let meal: String
        /// Serialised NutritionSnapshot JSON — same format stored in Note.nutritionProfile.
        let nutritionProfileJson: String?
        /// Minutes ago the meal started; 0 = eating right now.
        let minutesAgo: Int
    }

    /// Maps a CGM trend arrow string to mmol/L per minute velocity.
    private static func trendArrowToVelocity(_ arrow: String?) -> Double {
        switch arrow {
        case "↑↑": return  0.100
        case "↑":   return  0.067
        case "↗":   return  0.033
        case "→":   return  0.000
        case "↘":   return -0.033
        case "↓":   return -0.067
        case "↓↓": return -0.100
        default:    return  0.000
        }
    }

    /// Decodes a cached `POST /api/glucose-calculations/` response body.
    static func decodeGlucoseCalculationsResponse(from data: Data) -> GlucoseCalculationsResponse? {
        let decoder = GlucoseMonitorAPI.jsonDecoder()
        guard let envelope = try? decoder.decode(GlucoseCalculationsResponse.Envelope.self, from: data) else {
            return nil
        }
        return envelope.data
    }

    static func fetchGlucoseCalculations(
        currentGlucose: Double,
        trendArrow: String? = nil,
        prospectiveSnapshot: NutritionSnapshot? = nil
    ) async throws -> GlucoseCalculationsResponse {
        try await fetchGlucoseCalculationsWithRawResponse(
            currentGlucose: currentGlucose,
            trendArrow: trendArrow,
            prospectiveSnapshot: prospectiveSnapshot
        ).response
    }

    static func fetchGlucoseCalculationsWithRawResponse(
        currentGlucose: Double,
        trendArrow: String? = nil,
        prospectiveSnapshot: NutritionSnapshot? = nil
    ) async throws -> (response: GlucoseCalculationsResponse, rawData: Data) {
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
                let prospectiveNotes: [ProspectiveNote]?
                let currentTrendMmolPerMin: Double
            }

            let tz = TimeZone.current
            // Same as web `getClientTimeInfo()` / note payloads: naive local wall time, not UTC ISO8601 with Z.
            // Backend compares this to note timestamps (also local wall time) for COB windows and decay.

            var prospectiveNotes: [ProspectiveNote]? = nil
            if let snap = prospectiveSnapshot, let carbs = snap.totalCarbs, carbs > 0 {
                // Serialise the snapshot fields into the nutritionProfileJson the backend expects.
                let profileJson = snapshotToNutritionProfileJson(snap)
                prospectiveNotes = [ProspectiveNote(
                    carbs: snap.totalCarbs,
                    insulin: nil,          // no insulin yet — user hasn't dosed
                    meal: "Prospective",
                    nutritionProfileJson: profileJson,
                    minutesAgo: 0
                )]
            }

            let body = Body(
                currentGlucose: currentGlucose,
                includePredictionFactors: true,
                clientTimeInfo: TimeInfo(
                    timestamp: formatNoteTimestampForRequest(Date()),
                    timezone: tz.identifier,
                    timezoneOffset: tz.secondsFromGMT() / 60   // iOS-9 fix: remove erroneous negation; header (line 350) and body must agree
                ),
                prospectiveNotes: prospectiveNotes,
                currentTrendMmolPerMin: trendArrowToVelocity(trendArrow)
            )
            req.httpBody = try JSONEncoder().encode(body)

            let (data, resp) = try await URLSession.shared.data(for: req)
            try checkStatus(resp, data: data)

            let decoder = GlucoseMonitorAPI.jsonDecoder()
            let envelope = try decoder.decode(GlucoseCalculationsResponse.Envelope.self, from: data)
            guard let result = envelope.data else {
                throw GlucoseMonitorAPI.APIError.decoding(
                    NSError(
                        domain: "BackendAPI", code: 0,
                        userInfo: [NSLocalizedDescriptionKey: envelope.message ?? "No calculation data returned"]
                    )
                )
            }
            return (result, data)
        }
    }

    /// Converts a NutritionSnapshot into the JSON string expected by Note.nutritionProfile /
    /// ProspectiveNoteDTO.nutritionProfileJson on the backend.
    static func snapshotToNutritionProfileJson(_ snap: NutritionSnapshot) -> String? {
        struct ProfileFields: Encodable {
            let absorptionMode: String?
            let estimatedGi: Double?
            let glycemicLoad: Double?
            let fiber: Double?
            let protein: Double?
            let fat: Double?
            let absorptionSpeedClass: String?
            let totalCarbs: Double?
            let patternName: String?
            let bolusStrategy: String?
            let suggestedDurationHours: Double?
        }
        let fields = ProfileFields(
            absorptionMode: snap.absorptionMode,
            estimatedGi: snap.estimatedGi,
            glycemicLoad: snap.glycemicLoad,
            fiber: snap.fiber,
            protein: snap.protein,
            fat: snap.fat,
            absorptionSpeedClass: snap.absorptionSpeedClass,
            totalCarbs: snap.totalCarbs,
            patternName: snap.patternName,
            bolusStrategy: snap.bolusStrategy,
            suggestedDurationHours: snap.suggestedDurationHours
        )
        return (try? JSONEncoder().encode(fields)).flatMap { String(data: $0, encoding: .utf8) }
    }

    // MARK: - Insulin preferences

    static func fetchInsulinCatalog(category: String? = nil) async throws -> [InsulinCatalogEntry] {
        try await performWithRefresh {
            let path = category.map { "/api/insulin-catalog?category=\($0)" } ?? "/api/insulin-catalog"
            let req = try authorizedRequest(path: path)
            let (data, resp) = try await URLSession.shared.data(for: req)
            try checkStatus(resp, data: data)
            return try GlucoseMonitorAPI.jsonDecoder().decode([InsulinCatalogEntry].self, from: data)
        }
    }

    static func fetchInsulinPreferences() async throws -> UserInsulinPreferences {
        try await performWithRefresh {
            let req = try authorizedRequest(path: "/api/user/insulin-preferences")
            let (data, resp) = try await URLSession.shared.data(for: req)
            try checkStatus(resp, data: data)
            return try GlucoseMonitorAPI.jsonDecoder().decode(UserInsulinPreferences.self, from: data)
        }
    }

    /// Saves insulin preferences. `longActingInjectionTime` ("HH:mm") gates the long-acting logging
    /// action: nil leaves the stored value unchanged, "" clears it, "HH:mm" sets it.
    static func saveInsulinPreferences(rapidCode: String, longActingCode: String,
                                       longActingInjectionTime: String? = nil) async throws -> UserInsulinPreferences {
        try await performWithRefresh {
            var req = try authorizedRequest(path: "/api/user/insulin-preferences", method: "PUT")
            struct Body: Encodable {
                let rapidInsulinCode: String
                let longActingInsulinCode: String
                let longActingInjectionTime: String?
            }
            req.httpBody = try JSONEncoder().encode(Body(
                rapidInsulinCode: rapidCode,
                longActingInsulinCode: longActingCode,
                longActingInjectionTime: longActingInjectionTime))
            let (data, resp) = try await URLSession.shared.data(for: req)
            try checkStatus(resp, data: data)
            return try GlucoseMonitorAPI.jsonDecoder().decode(UserInsulinPreferences.self, from: data)
        }
    }

    /// On-demand LibreLinkUp sync: asks the backend to fetch fresh CGM readings immediately,
    /// bypassing the periodic scheduler, so the chart cache is up to date before we read it.
    /// The backend serialises per-user syncs and coalesces rapid repeat calls. Best-effort —
    /// callers should treat failure as non-fatal (the cached data still loads). Returns the
    /// server outcome string (e.g. "NEW_DATA", "NO_CHANGE", "IN_PROGRESS").
    @discardableResult
    static func syncLibreNow() async throws -> String {
        try await performWithRefresh {
            let req = try authorizedRequest(path: "/api/libre/sync-now", method: "POST")
            let (data, resp) = try await URLSession.shared.data(for: req)
            try checkStatus(resp, data: data)
            struct Resp: Decodable { let outcome: String }
            return (try? GlucoseMonitorAPI.jsonDecoder().decode(Resp.self, from: data))?.outcome ?? "OK"
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
            let decoder = GlucoseMonitorAPI.jsonDecoder()
            return try decoder.decode([NightscoutEntry].self, from: data)
        }
    }

    /// Stored chart points written by the backend when a live sync succeeds (`EnhancedNightscoutService` strategy 3).
    static func fetchNightscoutChartData(count: Int = 100, since: Date? = nil) async throws -> [NightscoutEntry] {
        try await performWithRefresh {
            var path = "/api/nightscout/chart-data?count=\(count)"
            if let since {
                let epochMs = Int64(since.timeIntervalSince1970 * 1000)
                path += "&since=\(epochMs)"
            }
            let req = try authorizedRequest(path: path)
            let (data, resp) = try await URLSession.shared.data(for: req)
            try checkStatus(resp, data: data)
            return try GlucoseMonitorAPI.jsonDecoder().decode([NightscoutEntry].self, from: data)
        }
    }

    /// Fetches Nightscout entries using a progressive fallback strategy (live → stored → chart-data).
    ///
    /// iOS-P1-5 fix: the `useStored` fallback (strategy 2) is only attempted when the live call
    /// throws an error — not when it succeeds but returns an empty list. An empty live response
    /// means the backend successfully reached Nightscout and got 0 entries; hammering `useStored`
    /// and `chart-data` in that case wastes RPS and battery without adding new data.
    /// Strategies 2 and 3 are still tried when strategy 1 throws (network / 5xx).
    static func fetchNightscoutEntriesWithFallbacks(count: Int) async throws -> [NightscoutEntry] {
        var firstError: Error?

        // Strategy 1: live Nightscout proxy.
        do {
            let fresh = try await fetchNightscoutEntries(count: count, useStored: false)
            // If the live call succeeded (no throw), return whatever we got — even empty.
            // Falling through to strategy 2 when the server returned 0 entries just adds
            // unnecessary HTTP round-trips.
            return fresh
        } catch {
            firstError = error
        }

        // Strategies 2 & 3 only run when strategy 1 threw (backend unreachable, 5xx, etc.).
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
            let dto = try GlucoseMonitorAPI.jsonDecoder().decode(UserDataSourceNightscoutResponse.self, from: data)
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
            let decoder = GlucoseMonitorAPI.jsonDecoder()
            return try decoder.decode(AiAnalysisResult.self, from: data)
        }
    }

    /// Streams markdown tokens from the backend NDJSON endpoint.
    /// Calls `onToken` on the main actor for each `{"type":"token","token":"..."}` line.
    /// Returns when the `{"type":"done"}` event is received or the stream ends.
    /// - Parameter provider: `"auto"` (default), `"qwen"`, or `"ollama"`.
    static func streamAiRetrospective(
        windowHours: Int = 12,
        provider: String = "auto",
        onToken: @MainActor @escaping (String) -> Void
    ) async throws {
        struct Body: Encodable { let windowHours: Int; let provider: String }
        struct StreamEvent: Decodable {
            let type: String
            let token: String?
        }

        var req = try authorizedRequest(path: "/api/ai-insights/retrospective/stream", method: "POST")
        req.httpBody = try JSONEncoder().encode(Body(windowHours: windowHours, provider: provider))

        let (bytes, resp) = try await URLSession.shared.bytes(for: req)
        try checkStatus(resp, data: Data())

        for try await line in bytes.lines {
            guard !line.isEmpty,
                  let data = line.data(using: .utf8),
                  let event = try? GlucoseMonitorAPI.jsonDecoder().decode(StreamEvent.self, from: data)
            else { continue }

            if event.type == "done" { break }
            if event.type == "token", let tok = event.token {
                await onToken(tok)
            }
        }
    }

    // MARK: - Nutrition

    /// Send a meal photo to the backend vision LLM and get a NutritionSnapshot back.
    static func analyzePhotoNutrition(image: UIImage) async throws -> NutritionSnapshot {
        let squareImage = cropToSquare(image)
        let resized = resizeImage(squareImage, maxSide: 1024)
        guard let jpeg = compressUnder1MB(resized) else {
            throw GlucoseMonitorAPI.APIError.decoding(
                NSError(domain: "BackendAPI", code: 0,
                        userInfo: [NSLocalizedDescriptionKey: "Could not compress image under 1 MB"])
            )
        }
        return try await performWithRefresh {
            var req = try authorizedRequest(path: "/api/nutrition/analyze-image", method: "POST")
            let boundary = "Boundary-\(UUID().uuidString)"
            req.setValue("multipart/form-data; boundary=\(boundary)", forHTTPHeaderField: "Content-Type")
            var body = Data()
            body.append("--\(boundary)\r\n".data(using: .utf8)!)
            body.append("Content-Disposition: form-data; name=\"photo\"; filename=\"meal.jpg\"\r\n".data(using: .utf8)!)
            body.append("Content-Type: image/jpeg\r\n\r\n".data(using: .utf8)!)
            body.append(jpeg)
            body.append("\r\n--\(boundary)--\r\n".data(using: .utf8)!)
            req.httpBody = body
            req.timeoutInterval = 300
            let (data, resp) = try await photoAnalysisSession.data(for: req)
            try checkStatus(resp, data: data)
            return try GlucoseMonitorAPI.jsonDecoder().decode(NutritionSnapshot.self, from: data)
        }
    }

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
            return try GlucoseMonitorAPI.jsonDecoder().decode(NutritionSnapshot.self, from: data)
        }
    }

    // MARK: - Version

    static func fetchBackendVersion() async throws -> BackendVersionPayload {
        try await performWithRefresh {
            let req = try authorizedRequest(path: "/api/version/")
            let (data, resp) = try await URLSession.shared.data(for: req)
            try checkStatus(resp, data: data)
            return try GlucoseMonitorAPI.jsonDecoder().decode(BackendVersionPayload.self, from: data)
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
            return try GlucoseMonitorAPI.jsonDecoder().decode(CompatibilityPayload.self, from: data)
        }
    }

    // MARK: - Glucose status (Nightscout mg/dL)

    static func glucoseStatus(_ value: Double?, unit: String?) -> String {
        guard let v = value else { return "unknown" }
        let mgdl = GlucoseUnit.isMmol(unit) ? GlucoseUnit.mmolToMgdl(v) : v
        switch mgdl {
        case ..<54: return "critical"
        case ..<70: return "low"
        case ...180: return "normal"
        default: return "high"
        }
    }
}
