import Foundation

// MARK: - Forecast at each log (backend /api/twin/anchors)

extension BackendAPI {

    /// A logged dose, meal or fast sugar the empirical twin forecasts from. `time` is the user's local
    /// wall time, read in `TimeZone.current` like notes.
    struct ForecastAnchor: Decodable, Identifiable, Equatable {
        let noteId: String
        let time: Date
        let label: String?
        let carbs: Double?
        let insulin: Double?

        var id: String { noteId }
    }

    /// The twin's 4 h forecast from one anchor beside the CGM actuals. Glucose is mmol/L.
    struct AnchorForecast: Decodable, Equatable {
        struct Point: Decodable, Equatable, Identifiable {
            let minute: Int
            let time: Date
            let glucose: Double
            let lower: Double
            let upper: Double
            var id: Int { minute }
        }

        struct Reading: Decodable, Equatable, Identifiable {
            let time: Date
            let glucose: Double
            var id: Date { time }
        }

        /// `kind` is INSULIN, BASAL, CARBS or ACTIVITY; `amount` is units, grams or minutes.
        struct Marker: Decodable, Equatable, Identifiable {
            let time: Date
            let kind: String
            let amount: Double
            var id: String { "\(kind)-\(time.timeIntervalSince1970)" }
        }

        /// `actual` and `hit` are nil while the CGM has no value at that horizon.
        struct Check: Decodable, Equatable {
            let minute: Int
            let forecast: Double?
            let actual: Double?
            let hit: Bool?
        }

        let anchor: ForecastAnchor
        let startGlucose: Double?
        let forecast: [Point]
        let actual: [Reading]
        let markers: [Marker]
        let checks: [Check]
        let coverage: Double
        let pending: Bool
    }

    static func fetchForecastAnchors(days: Int = 14) async throws -> [ForecastAnchor] {
        try await performWithRefresh {
            let req = try authorizedRequest(path: "/api/twin/anchors?days=\(days)")
            let (data, resp) = try await URLSession.shared.data(for: req)
            try checkStatus(resp, data: data)
            return try GlucoseMonitorAPI.jsonDecoder().decode([ForecastAnchor].self, from: data)
        }
    }

    static func fetchAnchorForecast(noteId: String) async throws -> AnchorForecast {
        try await performWithRefresh {
            let req = try authorizedRequest(path: "/api/twin/anchors/\(noteId)")
            let (data, resp) = try await URLSession.shared.data(for: req)
            try checkStatus(resp, data: data)
            return try GlucoseMonitorAPI.jsonDecoder().decode(AnchorForecast.self, from: data)
        }
    }
}
