import Foundation

/// How sick the user says they are. `severeUnresponsive` is only ever reached by accepting a server
/// step-up proposal, so it is never offered in a picker.
enum SickSeverity: String, Codable, CaseIterable {
    case mild = "MILD"
    case moderate = "MODERATE"
    case severe = "SEVERE"
    case severeUnresponsive = "SEVERE_UNRESPONSIVE"

    var selectable: Bool { self != .severeUnresponsive }
}

/// When the illness began, relative to now.
enum SickSince: String, Encodable {
    case now = "NOW"
    case thisMorning = "THIS_MORNING"
    case yesterday = "YESTERDAY"
}

/// Server status of sick mode. Decoding fails (and so the dashboard drops it) on an unknown severity
/// or a malformed `since`, the same tolerance as the watch strip.
struct SickModeStatus: Decodable, Equatable {
    let active: Bool
    let severity: SickSeverity?
    /// The user's wall-clock start (zone-less on the wire), read in the device time zone.
    let since: Date?
    let dayNumber: Int?
    /// Insulin sensitivity change in percent (e.g. -30), nil when not active.
    let isfPercent: Int?
    /// Basal need change in percent (e.g. 15), nil when not active.
    let basalNeedPercent: Int?
    let confirmationDue: Bool
    let stepUp: StepUp?

    struct StepUp: Decodable, Equatable {
        let noteId: UUID
        let toSeverity: SickSeverity?
        let showHelpLine: Bool
    }

    enum CodingKeys: String, CodingKey {
        case active, severity, since, dayNumber, isfPercent, basalNeedPercent, confirmationDue, stepUp
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        active = try c.decode(Bool.self, forKey: .active)
        severity = try c.decodeIfPresent(SickSeverity.self, forKey: .severity)
        if let raw = try c.decodeIfPresent(String.self, forKey: .since) {
            guard let d = BackendAPI.parseBackendDate(raw) else {
                throw DecodingError.dataCorruptedError(forKey: .since, in: c, debugDescription: "Bad date: \(raw)")
            }
            since = d
        } else {
            since = nil
        }
        dayNumber = try c.decodeIfPresent(Int.self, forKey: .dayNumber)
        isfPercent = try c.decodeIfPresent(Int.self, forKey: .isfPercent)
        basalNeedPercent = try c.decodeIfPresent(Int.self, forKey: .basalNeedPercent)
        confirmationDue = try c.decodeIfPresent(Bool.self, forKey: .confirmationDue) ?? false
        stepUp = try c.decodeIfPresent(StepUp.self, forKey: .stepUp)
    }

    init(active: Bool, severity: SickSeverity? = nil, since: Date? = nil, dayNumber: Int? = nil,
         isfPercent: Int? = nil, basalNeedPercent: Int? = nil, confirmationDue: Bool = false, stepUp: StepUp? = nil) {
        self.active = active
        self.severity = severity
        self.since = since
        self.dayNumber = dayNumber
        self.isfPercent = isfPercent
        self.basalNeedPercent = basalNeedPercent
        self.confirmationDue = confirmationDue
        self.stepUp = stepUp
    }
}
