import Foundation

// MARK: - Glycemic events (backend /api/glycemic-events)

extension BackendAPI {

    /// A detected unexplained glucose move. Times are the user's local wall time (naive
    /// `yyyy-MM-dd'T'HH:mm:ss`), which `GlucoseMonitorAPI.jsonDecoder()` reads in `TimeZone.current` -
    /// the same convention as notes, so markers line up with note markers. `category` and
    /// `promptOptions` are raw strings so categories the app doesn't know yet still decode.
    struct GlycemicEvent: Decodable, Identifiable, Equatable {
        let id: String
        let category: String
        let detectorCategory: String?
        let userLabel: String?
        let displayLabel: String
        let direction: String
        let phase: String
        let state: String
        let onsetAt: Date
        let windowStart: Date
        let windowEnd: Date
        let resolvesAt: Date?
        let confidence: Double?
        let suppressed: Bool
        let linkedEventId: String?
        let meanResidualMmol: Double
        let promptOptions: [String]

        var isProvisional: Bool { phase == "PROVISIONAL" }
        var isRise: Bool { direction == "RISE" }
        var isChild: Bool { linkedEventId != nil }
    }

    struct GlycemicEventHistoryEntry: Decodable, Equatable {
        let kind: String
        let at: Date
        let categoryBefore: String?
        let categoryAfter: String?
        let confidence: Double?
        let actor: String
        let reason: String?
    }

    struct GlycemicInsights: Decodable, Equatable {
        let days: Int
        let counts: [String: Int]
        let hourHistogram: [String: [Int]]
        let noEffectCount14d: Int
        let agreementRate: [String: Double]
    }

    private struct ConfirmGlycemicEventBody: Encodable {
        let category: String?
        let carbs: Double?
        let insulin: Double?
    }

    static func fetchGlycemicEvents(from: Date, to: Date) async throws -> [GlycemicEvent] {
        try await performWithRefresh {
            let f = formatNoteTimestampForRequest(from), t = formatNoteTimestampForRequest(to)
            let req = try authorizedRequest(path: "/api/glycemic-events?from=\(f)&to=\(t)")
            let (data, resp) = try await URLSession.shared.data(for: req)
            try checkStatus(resp, data: data)
            return try GlucoseMonitorAPI.jsonDecoder().decode([GlycemicEvent].self, from: data)
        }
    }

    /// The one event to prompt about now; nil when the server answers 204.
    static func fetchGlycemicPrompt() async throws -> GlycemicEvent? {
        try await performWithRefresh {
            let req = try authorizedRequest(path: "/api/glycemic-events/prompt")
            let (data, resp) = try await URLSession.shared.data(for: req)
            if (resp as? HTTPURLResponse)?.statusCode == 204 { return nil }
            try checkStatus(resp, data: data)
            return try GlucoseMonitorAPI.jsonDecoder().decode(GlycemicEvent.self, from: data)
        }
    }

    static func confirmGlycemicEvent(id: String, category: String?, carbs: Double?, insulin: Double?) async throws -> GlycemicEvent {
        try await performWithRefresh {
            var req = try authorizedRequest(path: "/api/glycemic-events/\(id)/confirm", method: "POST")
            req.httpBody = try JSONEncoder().encode(ConfirmGlycemicEventBody(category: category, carbs: carbs, insulin: insulin))
            let (data, resp) = try await URLSession.shared.data(for: req)
            try checkStatus(resp, data: data)
            return try GlucoseMonitorAPI.jsonDecoder().decode(GlycemicEvent.self, from: data)
        }
    }

    static func dismissGlycemicEvent(id: String) async throws -> GlycemicEvent {
        try await performWithRefresh {
            let req = try authorizedRequest(path: "/api/glycemic-events/\(id)/dismiss", method: "POST")
            let (data, resp) = try await URLSession.shared.data(for: req)
            try checkStatus(resp, data: data)
            return try GlucoseMonitorAPI.jsonDecoder().decode(GlycemicEvent.self, from: data)
        }
    }

    static func fetchGlycemicEventHistory(id: String) async throws -> [GlycemicEventHistoryEntry] {
        try await performWithRefresh {
            let req = try authorizedRequest(path: "/api/glycemic-events/\(id)/history")
            let (data, resp) = try await URLSession.shared.data(for: req)
            try checkStatus(resp, data: data)
            return try GlucoseMonitorAPI.jsonDecoder().decode([GlycemicEventHistoryEntry].self, from: data)
        }
    }

    static func fetchGlycemicInsights(days: Int = 30) async throws -> GlycemicInsights {
        try await performWithRefresh {
            let req = try authorizedRequest(path: "/api/glycemic-events/insights?days=\(days)")
            let (data, resp) = try await URLSession.shared.data(for: req)
            try checkStatus(resp, data: data)
            return try GlucoseMonitorAPI.jsonDecoder().decode(GlycemicInsights.self, from: data)
        }
    }
}

/// Short one-tap button titles for server categories. Unknown categories fall back to a title-cased name.
enum GlycemicCategory {
    private static let titles: [String: String] = [
        "UNLOGGED_FOOD": "I ate",
        "UNDER_ESTIMATED_FOOD": "Ate more than logged",
        "STRESS": "Stress",
        "ABSORPTION_DELAY": "Late insulin",
        "LIPODYSTROPHY": "Injection site",
        "DAWN_PHENOMENON": "Dawn",
        "ANAEROBIC_ACTIVITY": "Strength workout",
        "UNLOGGED_INSULIN": "Took unlogged insulin",
        "UNDER_ESTIMATED_INSULIN": "Took more than logged",
        "AEROBIC_ACTIVITY": "Cardio",
    ]

    static func buttonTitle(_ raw: String) -> String {
        titles[raw] ?? raw.replacingOccurrences(of: "_", with: " ").capitalized
    }

    static func takesCarbs(_ raw: String) -> Bool { raw == "UNLOGGED_FOOD" || raw == "UNDER_ESTIMATED_FOOD" }

    static func takesInsulin(_ raw: String) -> Bool { raw == "UNLOGGED_INSULIN" || raw == "UNDER_ESTIMATED_INSULIN" }
}
