import Foundation

// MARK: - Sick mode (backend /api/sick-mode)

extension BackendAPI {

    private struct StartSickModeBody: Encodable { let severity: SickSeverity; let since: SickSince }
    private struct SickSeverityBody: Encodable { let severity: SickSeverity }
    private struct EndSickModeBody: Encodable { let reason: String }
    private struct SickStepUpBody: Encodable { let noteId: UUID; let accept: Bool }

    /// Every endpoint answers with the resulting status; a rejected command is HTTP 400.
    private static func sickModeRequest(_ path: String, method: String, body: (any Encodable)? = nil) async throws -> SickModeStatus {
        try await performWithRefresh {
            var req = try authorizedRequest(path: "/api/sick-mode" + path, method: method)
            if let body { req.httpBody = try JSONEncoder().encode(body) }
            let (data, resp) = try await URLSession.shared.data(for: req)
            try checkStatus(resp, data: data)
            return try GlucoseMonitorAPI.jsonDecoder().decode(SickModeStatus.self, from: data)
        }
    }

    static func sickModeStatus() async throws -> SickModeStatus {
        try await sickModeRequest("", method: "GET")
    }

    static func startSickMode(_ severity: SickSeverity, since: SickSince) async throws -> SickModeStatus {
        try await sickModeRequest("/start", method: "POST", body: StartSickModeBody(severity: severity, since: since))
    }

    static func changeSickSeverity(_ severity: SickSeverity) async throws -> SickModeStatus {
        try await sickModeRequest("/severity", method: "PUT", body: SickSeverityBody(severity: severity))
    }

    static func confirmStillSick() async throws -> SickModeStatus {
        try await sickModeRequest("/confirm", method: "POST")
    }

    /// `reason` is "USER" or "MORNING_NO".
    static func endSickMode(reason: String) async throws -> SickModeStatus {
        try await sickModeRequest("/end", method: "POST", body: EndSickModeBody(reason: reason))
    }

    static func decideSickStepUp(noteId: UUID, accept: Bool) async throws -> SickModeStatus {
        try await sickModeRequest("/step-up", method: "POST", body: SickStepUpBody(noteId: noteId, accept: accept))
    }
}
