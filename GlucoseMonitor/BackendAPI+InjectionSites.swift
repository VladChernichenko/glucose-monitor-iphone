import Foundation

// MARK: - Injection sites (backend /api/injection-sites; the site itself is notes.siteZone)

extension BackendAPI {

    /// Site rotation for the body map. Times are local wall time, read in `TimeZone.current` like notes.
    struct InjectionSites: Decodable, Equatable {
        /// `status` is USED_24H (red), USED_72H (amber) or FREE.
        struct Zone: Decodable, Equatable {
            let zone: String
            let label: String
            let lastUsedAt: Date?
            let status: String
        }

        struct Warning: Decodable, Equatable {
            let zone: String
            let count: Int
            let message: String
        }

        /// `zone` is a zone code or "unknown".
        struct Recent: Decodable, Equatable {
            let noteId: String
            let time: Date
            let zone: String
            let units: Double
            let basal: Bool
        }

        let zones: [Zone]
        let suggested: String?
        let warning: Warning?
        let recent: [Recent]
    }

    static func fetchInjectionSites(rapid: Bool) async throws -> InjectionSites {
        try await performWithRefresh {
            let req = try authorizedRequest(path: "/api/injection-sites?insulin=\(rapid ? "rapid" : "basal")")
            let (data, resp) = try await URLSession.shared.data(for: req)
            try checkStatus(resp, data: data)
            return try GlucoseMonitorAPI.jsonDecoder().decode(InjectionSites.self, from: data)
        }
    }
}
