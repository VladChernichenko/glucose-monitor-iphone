import Foundation

extension BackendAPI {
    /// The dashboard watch strip (`watch` in the glucose-calculations response): what to look at right now.
    /// Glucose values are mmol/L, times are the user's wall time. A strip whose `state` is unknown is hidden.
    struct WatchStrip: Decodable, Equatable {
        enum State: String, Decodable {
            case calm = "CALM", urgentLow = "URGENT_LOW", urgentHigh = "URGENT_HIGH", unknown
            init(from decoder: Decoder) throws {
                self = Self(rawValue: try decoder.singleValueContainer().decode(String.self)) ?? .unknown
            }
        }
        enum Reason: String, Decodable {
            case lowNow = "LOW_NOW", treatingLow = "TREATING_LOW", forecastLow = "FORECAST_LOW"
            case carbsLanding = "CARBS_LANDING", highForecast = "HIGH_FORECAST"
            case insulinLanding = "INSULIN_LANDING", smallRise = "SMALL_RISE"
            case watching = "WATCHING", dipAhead = "DIP_AHEAD", unknown
            init(from decoder: Decoder) throws {
                self = Self(rawValue: try decoder.singleValueContainer().decode(String.self)) ?? .unknown
            }
        }
        enum Kind: String, Decodable {
            case carbs = "CARBS", insulin = "INSULIN", noAction = "NO_ACTION", refused = "REFUSED", unknown
            init(from decoder: Decoder) throws {
                self = Self(rawValue: try decoder.singleValueContainer().decode(String.self)) ?? .unknown
            }
        }
        enum ActivityEstimate: String, Decodable {
            case learned = "LEARNED", `default` = "DEFAULT", unknown
            init(from decoder: Decoder) throws {
                self = Self(rawValue: try decoder.singleValueContainer().decode(String.self)) ?? .unknown
            }
        }

        struct Suggestion: Decodable, Equatable {
            let kind: Kind
            let grams: Int?
            let units: Double?
            let refusalCode: String?
            let targetMmol: Double?
            let isf: Double?
            let minWithCarbs: Double?
        }

        struct GlucosePoint: Decodable, Equatable {
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

        /// Dates come as zone-less `LocalDateTime` strings, parsed like `CarbAdvice`'s.
        fileprivate static func date<K: CodingKey>(_ c: KeyedDecodingContainer<K>, _ key: K) throws -> Date {
            let s = try c.decode(String.self, forKey: key)
            guard let d = BackendAPI.parseBackendDate(s) else {
                throw DecodingError.dataCorruptedError(forKey: key, in: c, debugDescription: "Bad date: \(s)")
            }
            return d
        }

        /// False when this app version doesn't know the state or the reason (so it can't phrase it).
        var isKnown: Bool { state != .unknown && reason != .unknown }
    }
}

/// The strip's two lines, in the user's glucose unit.
enum WatchStripText {
    static func headline(_ s: BackendAPI.WatchStrip, unit: String) -> String {
        switch s.reason {
        case .lowNow: return "Low now"
        case .treatingLow: return "Treating low"
        case .forecastLow, .carbsLanding:
            return "Low likely ~\(time(s.low?.at)) (\(glucose(s.low?.mmol, unit)))"
        case .highForecast, .insulinLanding, .smallRise:
            return "High ahead: \(glucose(s.landing?.mmol, unit)) at \(time(s.landing?.at))"
        case .watching, .dipAhead:
            return "Watching \u{00B7} \(String(format: "%.1f", s.iob ?? 0)) U, \(String(format: "%.0f", s.cob ?? 0)) g active"
        case .unknown: return ""
        }
    }

    static func detail(_ s: BackendAPI.WatchStrip, unit: String) -> String {
        let next = "recheck \(ChatFormatting.clock(s.nextCheckAt))"
        let sug = s.suggestion
        switch s.reason {
        case .lowNow:
            return "Take \(sug?.grams ?? 15) g fast carbs \u{00B7} \(next)"
        case .treatingLow:
            let target = glucose(BackendAPI.CarbAdvice.furtherCarbsThresholdMmol, unit)
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
            return "Correction \(units) U (target \(target), ISF \(isf)) \u{00B7} \(next)"
        case .insulinLanding:
            return "Insulin still landing, no correction \u{00B7} \(next)"
        case .smallRise:
            return "Small rise, no correction \u{00B7} \(next)"
        case .watching, .dipAhead:
            // No landing to state: no detail line rather than "Lands -- by --:--".
            if s.reason == .watching && s.landing == nil { return "" }
            var text = s.reason == .watching
                ? "Lands \(glucose(s.landing?.mmol, unit)) by \(time(s.landing?.at))"
                : "Dip to \(glucose(s.low?.mmol, unit)) around \(time(s.low?.at)), have 10\u{2013}15 g ready"
            if s.activityEstimate == .default { text += " \u{00B7} activity estimate still rough" }
            return text
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
        mmol.map { ChatFormatting.glucose(mmol: $0, unit: unit) } ?? "--"
    }

    private static func glucose(_ mmol: Double?, _ unit: String) -> String {
        guard let mmol else { return "--" }
        return "\(ChatFormatting.glucose(mmol: mmol, unit: unit)) \(ChatFormatting.unitLabel(unit))"
    }

    private static func time(_ date: Date?) -> String { date.map(ChatFormatting.clock) ?? "--:--" }
}

extension AppState {
    /// Older than this, the last successful calculations fetch is too old to act on.
    static let watchStripMaxAge: TimeInterval = 600

    /// The watch strip to show now.
    var visibleWatchStrip: BackendAPI.WatchStrip? { watchStrip(at: Date()) }

    /// The watch strip to show at `now`, or nil: hidden when the data behind it is stale, restored from cache
    /// or more than `watchStripMaxAge` old, when the backend sent none, and when this app version can't
    /// phrase it. A dose or carbs suggestion is also hidden once its recheck time has passed: an old
    /// "take 1 U" must never stay on screen.
    func watchStrip(at now: Date) -> BackendAPI.WatchStrip? {
        guard !libreDataStale, !calculationsStale, !calculationsFromCache,
              let fetchedAt = calculationsFetchedAt, now.timeIntervalSince(fetchedAt) <= Self.watchStripMaxAge,
              let strip = calculations?.watch, strip.isKnown else { return nil }
        let kind = strip.suggestion?.kind
        if (kind == .insulin || kind == .carbs) && strip.nextCheckAt < now { return nil }
        return strip
    }

    /// The carb advice card the chat shows, or nil (taken, stale, cached, expired, or a low prompt is open).
    var visibleCarbAdvice: BackendAPI.CarbAdvice? {
        BackendAPI.CarbAdvice.visible(calculations?.carbAdvice,
                                      calculationsStale: calculationsStale,
                                      calculationsFromCache: calculationsFromCache,
                                      hypoPromptOpen: openHypoEvent != nil,
                                      tookIdentity: tookCarbAdviceIdentity)
    }

    /// A low strip opens the chat only when the carb card is actually there; otherwise the tap shows the chart.
    func watchStripTapOpensChat(_ strip: BackendAPI.WatchStrip) -> Bool {
        strip.state == .urgentLow && visibleCarbAdvice != nil
    }
}
