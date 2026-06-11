import Foundation

/// Persisted dashboard payload so the UI can render immediately on cold launch.
enum DashboardCache {
    static let storageKey = "gm_dashboard_cache_v1"

    struct Payload: Codable {
        var savedAt: Date
        var preferredGlucoseUnit: String
        var dataSource: String
        var currentReading: CachedReading?
        var glucoseHistory: [CachedChartPoint]
        /// Raw JSON body from `POST /api/glucose-calculations/` (envelope).
        var calculationsResponseJSON: Data?
        var notes: [CachedNote]
    }

    struct CachedReading: Codable {
        var timestamp: Date?
        var value: Double?
        var trend: Int?
        var trendArrow: String?
        var status: String?
        var unit: String?
    }

    struct CachedChartPoint: Codable {
        var time: Date
        var mmol: Double
    }

    struct CachedNote: Codable {
        var id: String
        var timestamp: Date?
        var carbs: Double
        var insulin: Double
        var meal: String
        var comment: String?
        var glucoseValue: Double?
        var absorptionMode: String?
        var nutritionProfile: String?
        var type: String?
        var photoUrl: String?
    }

    static func load() -> Payload? {
        guard let data = GlucoseMonitorAPI.sharedDefaults().data(forKey: storageKey) else { return nil }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .secondsSince1970
        return try? decoder.decode(Payload.self, from: data)
    }

    static func save(_ payload: Payload) {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .secondsSince1970
        guard let data = try? encoder.encode(payload) else { return }
        GlucoseMonitorAPI.sharedDefaults().set(data, forKey: storageKey)
    }

    static func clear() {
        GlucoseMonitorAPI.sharedDefaults().removeObject(forKey: storageKey)
    }

    @MainActor
    static func capture(from state: AppState, calculationsResponseJSON: Data? = nil) {
        guard state.isAuthenticated else { return }
        let payload = Payload(
            savedAt: Date(),
            preferredGlucoseUnit: state.preferredGlucoseUnit,
            dataSource: state.dataSource,
            currentReading: state.currentReading.map { reading in
                CachedReading(
                    timestamp: reading.timestamp,
                    value: reading.value,
                    trend: reading.trend,
                    trendArrow: reading.trendArrow,
                    status: reading.status,
                    unit: reading.unit
                )
            },
            glucoseHistory: state.glucoseHistory.map { CachedChartPoint(time: $0.time, mmol: $0.mmol) },
            calculationsResponseJSON: calculationsResponseJSON,
            notes: state.notes.map { note in
                CachedNote(
                    id: note.id,
                    timestamp: note.timestamp,
                    carbs: note.carbs,
                    insulin: note.insulin,
                    meal: note.meal,
                    comment: note.comment,
                    glucoseValue: note.glucoseValue,
                    absorptionMode: note.absorptionMode,
                    nutritionProfile: note.nutritionProfile,
                    type: note.type,
                    photoUrl: note.photoUrl
                )
            }
        )
        save(payload)
    }
}

