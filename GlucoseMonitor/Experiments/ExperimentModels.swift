import Foundation

// MARK: - Enums

enum ExperimentType: String, Codable, CaseIterable {
    case basalCheck  = "BASAL_CHECK"
    case carbFactor  = "CARB_FACTOR"
    case isfOneUnit  = "ISF_ONE_UNIT"

    var title: String {
        switch self {
        case .basalCheck: return "Basal Rate Check"
        case .carbFactor: return "Carb Factor Test"
        case .isfOneUnit: return "ISF — 1-Unit Test"
        }
    }

    var subtitle: String {
        switch self {
        case .basalCheck: return "Verify background insulin stability"
        case .carbFactor: return "Find your carb sensitivity"
        case .isfOneUnit: return "Find your insulin sensitivity"
        }
    }

    var description: String {
        switch self {
        case .basalCheck:
            return "Skip eating and bolusing for 4–6 hours. We track whether your glucose stays flat, verifying your basal rate is set correctly."
        case .carbFactor:
            return "Eat exactly 15g of fast-acting carbs with no insulin. We measure the glucose rise to calculate how much 1g of carbs affects your blood sugar."
        case .isfOneUnit:
            return "Inject 1 unit of rapid insulin during stable hyperglycaemia (11–14 mmol/L). We track the drop over 4–5 hours to determine your Insulin Sensitivity Factor."
        }
    }

    var durationText: String {
        switch self {
        case .basalCheck: return "4–6 hours"
        case .carbFactor: return "1–2 hours"
        case .isfOneUnit: return "4–5 hours"
        }
    }

    /// Minimum wall-clock minutes between start and the "Finish" button enabling.
    /// Mirrors the backend's `ExperimentService.minElapsedMinutes(Type)` floor — the
    /// server returns 400 below this, so enforcing client-side avoids the round-trip.
    var minimumMinutesToFinish: Int {
        switch self {
        case .basalCheck:  return 180  // 3 h floor; protocol target 4–6 h
        case .carbFactor:  return 60
        case .isfOneUnit:  return 180  // 3 h floor; protocol target 4–5 h
        }
    }

    var systemImage: String {
        switch self {
        case .basalCheck: return "waveform.path.ecg.rectangle"
        case .carbFactor: return "fork.knife"
        case .isfOneUnit: return "syringe"
        }
    }

    var alarmSchedule: [(minutes: Int, message: String)] {
        switch self {
        case .basalCheck:
            return [
                (60,  "⏰ Record your glucose — 1 hour into your Basal Check"),
                (120, "⏰ Record your glucose — 2 hours into your Basal Check"),
                (180, "⏰ Record your glucose — 3 hours into your Basal Check"),
                (240, "✅ You can finish the Basal Rate Check now"),
            ]
        case .carbFactor:
            return [
                (30,  "⏰ Record your glucose — 30 minutes after eating"),
                (45,  "⏰ Record your glucose — 45 minutes after eating"),
                (60,  "✅ You can finish the Carb Factor Test now"),
            ]
        case .isfOneUnit:
            return [
                (60,  "⏰ Record your glucose — 1 hour after injection"),
                (120, "⏰ Record your glucose — 2 hours after injection"),
                (180, "⏰ Record your glucose — 3 hours after injection"),
                (240, "✅ You can finish the ISF test now"),
            ]
        }
    }

    var prerequisites: [String] {
        switch self {
        case .basalCheck:
            return [
                "No food for at least 3 hours",
                "No rapid insulin for at least 4 hours",
                "Stable glucose for 30 minutes",
            ]
        case .carbFactor:
            return [
                "Completed a successful Basal Rate Check",
                "No active insulin (IOB < 0.3u)",
                "No active carbs (COB < 5g)",
                "Have 15g of fast-acting carbs ready",
                "(e.g. glucose tablets or gummy bears)",
            ]
        case .isfOneUnit:
            return [
                "Completed a successful Basal Rate Check",
                "Glucose between 11–14 mmol/L",
                "No active insulin (IOB < 0.3u)",
                "No active carbs (COB < 5g)",
                "4–5 hours free with no planned meals",
            ]
        }
    }
}

enum ExperimentStatus: String, Codable {
    case pending    = "PENDING"
    case inProgress = "IN_PROGRESS"
    case completed  = "COMPLETED"
    case abandoned  = "ABANDONED"
}

// MARK: - Preferences

/// Persists the "Notify me when ready" toggle on the Experiments "Not Ready Yet" sheet,
/// per experiment type, so the toggle reflects the user's last choice the next time the
/// sheet is shown (e.g. after tapping "Got it" and reopening the experiment).
enum ExperimentNotifyPreference {
    private static func key(for type: ExperimentType) -> String {
        "experiment.notifyWhenReady.\(type.rawValue)"
    }

    static func isEnabled(for type: ExperimentType, defaults: UserDefaults = .standard) -> Bool {
        defaults.bool(forKey: key(for: type))
    }

    static func setEnabled(_ enabled: Bool, for type: ExperimentType, defaults: UserDefaults = .standard) {
        defaults.set(enabled, forKey: key(for: type))
    }
}

// MARK: - API Models

struct ExperimentReading: Codable, Identifiable {
    let id: UUID?
    let recordedAt: String
    let glucoseMmol: Double
    let minutesElapsed: Int
    let label: String?
}

struct ExperimentModel: Codable, Identifiable {
    let id: UUID
    let type: ExperimentType
    let status: ExperimentStatus
    let startedAt: String?
    let completedAt: String?
    let gramsConsumed: Double?
    let unitsInjected: Double?
    let computedIsf: Double?
    let computedCarbRatio: Double?
    let isStable: Bool?
    let resultNotes: String?
    let createdAt: String?
    let readings: [ExperimentReading]
}

struct AvailableExperiment: Codable, Identifiable {
    var id: ExperimentType { type }
    let type: ExperimentType
    let title: String
    let description: String
    let durationMinutes: Int
    let available: Bool
    let lockReason: String?
    let lastComputedIsf: Double?
    let lastComputedCarbRatio: Double?
    let lastIsStable: Bool?
}

struct BackgroundStatus: Codable {
    let isClean: Bool
    let cobGrams: Double
    let iobUnits: Double
    let cleanInMinutes: Int
}

struct ExperimentResult: Codable {
    let computedIsf: Double?
    let computedCarbRatio: Double?
    let isStable: Bool?
    let savedToSettings: Bool
    let explanation: String?
    let experiment: ExperimentModel?
}

// MARK: - Request Models

struct StartExperimentRequest: Encodable {
    let type: ExperimentType
    let gramsConsumed: Double?
    let unitsInjected: Double?
}

struct RecordReadingRequest: Encodable {
    let glucoseMmol: Double
    let minutesElapsed: Int
    let label: String?
}
