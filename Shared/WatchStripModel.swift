import Foundation

/// Backend date/time strings. The backend sends naive local wall time (no time-zone suffix).
enum BackendDate {

    /// Interprets the naive form in the device's current time zone - not UTC - before falling back to
    /// ISO-8601 with an explicit zone (Z / ±HH:MM).
    static func parse(_ s: String) -> Date? {
        let df = DateFormatter()
        df.locale = Locale(identifier: "en_US_POSIX")
        df.timeZone = TimeZone.current
        for format in ["yyyy-MM-dd'T'HH:mm:ss", "yyyy-MM-dd'T'HH:mm:ss.SSS"] {
            df.dateFormat = format
            if let d = df.date(from: s) { return d }
        }
        let iso = ISO8601DateFormatter()
        iso.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let d = iso.date(from: s) { return d }
        iso.formatOptions = [.withInternetDateTime]
        return iso.date(from: s)
    }

    /// The backend's naive wall-time form, in the device's current time zone.
    static func format(_ date: Date) -> String {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = TimeZone.current
        f.dateFormat = "yyyy-MM-dd'T'HH:mm:ss"
        return f.string(from: date)
    }
}

/// Glucose and clock text shared by the phone and the watch. The backend works in mmol/L; mg/dL users see mg/dL.
enum GlucoseText {
    static func glucose(mmol: Double, unit: String) -> String {
        GlucoseUnit.isMgdl(unit)
            ? String(format: "%.0f", GlucoseUnit.mmolToMgdl(mmol))
            : String(format: "%.1f", mmol)
    }

    static func clock(_ date: Date) -> String {
        let f = DateFormatter()
        f.locale = Locale.current
        f.timeZone = TimeZone.current
        f.dateFormat = "HH:mm"
        return f.string(from: date)
    }

    static func unitLabel(_ unit: String) -> String { GlucoseUnit.isMgdl(unit) ? "mg/dL" : "mmol/L" }
}

/// The dashboard watch strip (`watch` in the glucose-calculations response and the watch glance): what to
/// look at right now. Glucose values are mmol/L, times are the user's wall time. A strip whose `state` is
/// unknown is hidden.
struct WatchStrip: Codable, Equatable {
    enum State: String, Codable {
        case calm = "CALM", urgentLow = "URGENT_LOW", urgentHigh = "URGENT_HIGH", unknown
        init(from decoder: Decoder) throws {
            self = Self(rawValue: try decoder.singleValueContainer().decode(String.self)) ?? .unknown
        }
    }
    enum Reason: String, Codable {
        case lowNow = "LOW_NOW", treatingLow = "TREATING_LOW", forecastLow = "FORECAST_LOW"
        case carbsLanding = "CARBS_LANDING", highForecast = "HIGH_FORECAST"
        case insulinLanding = "INSULIN_LANDING", smallRise = "SMALL_RISE"
        case watching = "WATCHING", dipAhead = "DIP_AHEAD", aboveTarget = "ABOVE_TARGET", unknown
        init(from decoder: Decoder) throws {
            self = Self(rawValue: try decoder.singleValueContainer().decode(String.self)) ?? .unknown
        }
    }
    enum Kind: String, Codable {
        case carbs = "CARBS", insulin = "INSULIN", noAction = "NO_ACTION", refused = "REFUSED", unknown
        init(from decoder: Decoder) throws {
            self = Self(rawValue: try decoder.singleValueContainer().decode(String.self)) ?? .unknown
        }
    }
    enum ActivityEstimate: String, Codable {
        case learned = "LEARNED", `default` = "DEFAULT", unknown
        init(from decoder: Decoder) throws {
            self = Self(rawValue: try decoder.singleValueContainer().decode(String.self)) ?? .unknown
        }
    }

    struct Suggestion: Codable, Equatable {
        let kind: Kind
        let grams: Int?
        let units: Double?
        let refusalCode: String?
        let targetMmol: Double?
        let isf: Double?
        let minWithCarbs: Double?
        /// Rapid insulin from the last 2 h, already in the forecast; a correction's `units` come on top of it.
        var takenUnits: Double? = nil
    }

    struct GlucosePoint: Codable, Equatable {
        let at: Date
        let mmol: Double

        enum CodingKeys: String, CodingKey { case at, mmol }

        init(at: Date, mmol: Double) {
            self.at = at
            self.mmol = mmol
        }

        init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            at = try WatchStrip.date(c, .at)
            mmol = try c.decode(Double.self, forKey: .mmol)
        }

        func encode(to encoder: Encoder) throws {
            var c = encoder.container(keyedBy: CodingKeys.self)
            try c.encode(BackendDate.format(at), forKey: .at)
            try c.encode(mmol, forKey: .mmol)
        }
    }

    let state: State
    let reason: Reason
    let suggestion: Suggestion?
    let low: GlucosePoint?
    let landing: GlucosePoint?
    let iob: Double?
    let cob: Double?
    let nextCheckAt: Date
    let activityEstimate: ActivityEstimate

    enum CodingKeys: String, CodingKey {
        case state, reason, suggestion, low, landing, iob, cob, nextCheckAt, activityEstimate
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        state = try c.decode(State.self, forKey: .state)
        reason = try c.decode(Reason.self, forKey: .reason)
        suggestion = try c.decodeIfPresent(Suggestion.self, forKey: .suggestion)
        low = try c.decodeIfPresent(GlucosePoint.self, forKey: .low)
        landing = try c.decodeIfPresent(GlucosePoint.self, forKey: .landing)
        iob = try c.decodeIfPresent(Double.self, forKey: .iob)
        cob = try c.decodeIfPresent(Double.self, forKey: .cob)
        nextCheckAt = try Self.date(c, .nextCheckAt)
        activityEstimate = try c.decodeIfPresent(ActivityEstimate.self, forKey: .activityEstimate) ?? .unknown
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(state, forKey: .state)
        try c.encode(reason, forKey: .reason)
        try c.encode(suggestion, forKey: .suggestion)
        try c.encode(low, forKey: .low)
        try c.encode(landing, forKey: .landing)
        try c.encode(iob, forKey: .iob)
        try c.encode(cob, forKey: .cob)
        try c.encode(BackendDate.format(nextCheckAt), forKey: .nextCheckAt)
        try c.encode(activityEstimate, forKey: .activityEstimate)
    }

    /// Dates come as zone-less `LocalDateTime` strings, parsed with `BackendDate.parse`.
    fileprivate static func date<K: CodingKey>(_ c: KeyedDecodingContainer<K>, _ key: K) throws -> Date {
        let s = try c.decode(String.self, forKey: key)
        guard let d = BackendDate.parse(s) else {
            throw DecodingError.dataCorruptedError(forKey: key, in: c, debugDescription: "Bad date: \(s)")
        }
        return d
    }

    /// False when this app version doesn't know the state or the reason (so it can't phrase it).
    var isKnown: Bool { state != .unknown && reason != .unknown }

    /// A dose or carbs suggestion whose recheck time has passed: an old "take 1 U" must never stay on screen.
    func suggestionExpired(at now: Date) -> Bool {
        let kind = suggestion?.kind
        return (kind == .insulin || kind == .carbs) && nextCheckAt < now
    }
}

/// The strip's two lines, in the user's glucose unit.
enum WatchStripText {
    static func headline(_ s: WatchStrip, unit: String) -> String {
        switch s.reason {
        case .lowNow: return "Low now"
        case .treatingLow: return "Treating low"
        case .forecastLow, .carbsLanding:
            return "Low likely ~\(time(s.low?.at)) (\(glucose(s.low?.mmol, unit)))"
        case .highForecast, .insulinLanding, .smallRise:
            return "High ahead: \(glucose(s.landing?.mmol, unit)) at \(time(s.landing?.at))"
        case .watching, .dipAhead:
            return "Watching \u{00B7} \(String(format: "%.1f", s.iob ?? 0)) U, \(String(format: "%.0f", s.cob ?? 0)) g active"
        case .aboveTarget:
            return "Above target \(glucose(s.suggestion?.targetMmol, unit))"
        case .unknown: return ""
        }
    }

    static func detail(_ s: WatchStrip, unit: String) -> String {
        let next = "recheck \(GlucoseText.clock(s.nextCheckAt))"
        let sug = s.suggestion
        switch s.reason {
        case .lowNow:
            return "Take \(sug?.grams ?? 15) g fast carbs \u{00B7} \(next)"
        case .treatingLow:
            let target = glucose(4.5, unit)
            return "Wait until \(target) and holding \u{00B7} \(next)"
        case .forecastLow:
            return "Take \(sug?.grams ?? 15) g now \u{2192} min \(glucose(sug?.minWithCarbs, unit)) \u{00B7} \(next)"
        case .carbsLanding:
            return "Wait for the \(sug?.grams ?? 15) g to act \u{00B7} \(next)"
        case .highForecast:
            if sug?.kind == .refused {
                return "No dose: \(refusal(sug?.refusalCode, unit)) \u{00B7} \(next)"
            }
            let units = String(format: "%.1f", sug?.units ?? 0)
            let target = bare(sug?.targetMmol, unit)
            let isf = bare(sug?.isf, unit)
            if let taken = sug?.takenUnits, taken > 0 {
                let total = String(format: "%.1f", (sug?.units ?? 0) + taken)
                return "Correction \(units) U \u{00B7} with \(String(format: "%.1f", taken)) U taken = \(total) U"
                    + " (target \(target), ISF \(isf)) \u{00B7} \(next)"
            }
            return "Correction \(units) U (target \(target), ISF \(isf)) \u{00B7} \(next)"
        case .insulinLanding:
            return "Insulin still landing, no correction \u{00B7} \(next)"
        case .smallRise:
            return "Small rise, no correction \u{00B7} \(next)"
        case .watching, .dipAhead, .aboveTarget:
            // No landing to state: no detail line rather than "Lands -- by --:--".
            if s.reason != .dipAhead && s.landing == nil { return "" }
            guard s.reason != .dipAhead else {
                return "Dip to \(glucose(s.low?.mmol, unit)) around \(time(s.low?.at)), have 10\u{2013}15 g ready"
            }
            let lands = "Lands \(glucose(s.landing?.mmol, unit)) by \(time(s.landing?.at))"
            // Landing above target but under 10: the backend attaches the correction to the green banner.
            guard sug?.kind == .insulin, let units = sug?.units else { return lands }
            let correction = "\(lands) \u{00B7} correction \(String(format: "%.1f", units)) U"
            guard let taken = sug?.takenUnits, taken > 0 else { return correction }
            return correction + " (with \(String(format: "%.1f", taken)) U taken = \(String(format: "%.1f", units + taken)) U)"
        case .unknown: return ""
        }
    }

    private static func refusal(_ code: String?, _ unit: String) -> String {
        switch code {
        case "GLUCOSE_BELOW_SAFE_THRESHOLD": return "glucose under \(glucose(3.9, unit))"
        case "DOSE_EXCEEDS_MAX_BOLUS": return "over your safety limit"
        case "SETTINGS_INVALID", "INSULIN_PARAMS_INCONSISTENT": return "check your ISF settings"
        case "READING_MISMATCH": return "sensor and app readings disagree"
        default: return "can't calculate"
        }
    }

    private static func bare(_ mmol: Double?, _ unit: String) -> String {
        mmol.map { GlucoseText.glucose(mmol: $0, unit: unit) } ?? "--"
    }

    private static func glucose(_ mmol: Double?, _ unit: String) -> String {
        guard let mmol else { return "--" }
        return "\(GlucoseText.glucose(mmol: mmol, unit: unit)) \(GlucoseText.unitLabel(unit))"
    }

    private static func time(_ date: Date?) -> String { date.map(GlucoseText.clock) ?? "--:--" }
}
