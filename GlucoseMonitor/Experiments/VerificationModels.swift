import Foundation

struct VerificationSummary: Codable {
    let nEvents: Int
    let meanError: Double?
    let consistencyScore: Double?
    let suggestedIsf: Double?
    let suggestedCarbRatio: Double?
    let suggestionReady: Bool
    let confidence: String?   // "LOW" | "MEDIUM" | "HIGH"
    let lastUpdated: String?
}

struct VerificationEventModel: Codable, Identifiable {
    let id: UUID?
    var stable_id: UUID { id ?? UUID() }
    let noteId: UUID?
    let status: String
    let baselineGlucose: Double?
    let actualGlucose2h: Double?
    let predictedDelta: Double?
    let actualDelta: Double?
    let error: Double?
    let relativeErrorPct: Double?
    let skipReason: String?
    let evaluatedAt: String?
    let createdAt: String?
}

extension VerificationSummary {
    var confidenceColor: String {
        switch confidence {
        case "HIGH":   return "green"
        case "MEDIUM": return "yellow"
        default:       return "red"
        }
    }

    var confidenceLabel: String { confidence ?? "N/A" }

    var accuracyPct: Double? {
        guard let cs = consistencyScore else { return nil }
        return cs * 100.0
    }
}
