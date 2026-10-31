import Foundation

// MARK: - Contract (backend Task 22: banner event / payload.banner, recheck)

extension BackendAPI {

    /// Past similar meals behind the history dose. Aggregates are nil when the episodes could not be read.
    struct HistoryBannerEpisodes: Decodable, Equatable {
        let count: Int
        let episodeIds: [String]
        let typicalDoseUnits: Double?
        let peakLow: Double?
        let peakHigh: Double?
        let landing: Double?

        private enum CodingKeys: String, CodingKey { case count, episodeIds, typicalDoseUnits, peakLow, peakHigh, landing }

        init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            count = try c.decodeIfPresent(Int.self, forKey: .count) ?? 0
            episodeIds = try c.decodeIfPresent([String].self, forKey: .episodeIds) ?? []
            typicalDoseUnits = try c.decodeIfPresent(Double.self, forKey: .typicalDoseUnits)
            peakLow = try c.decodeIfPresent(Double.self, forKey: .peakLow)
            peakHigh = try c.decodeIfPresent(Double.self, forKey: .peakHigh)
            landing = try c.decodeIfPresent(Double.self, forKey: .landing)
        }
    }

    /// "Your past similar meals needed more/less": the model dose against the history dose, both curves.
    /// Glucose is mmol/L. `historyLevel` only colours the card; the re-check is the authority.
    struct HistoryBanner: Decodable, Equatable {
        let modelUnits: Double
        let historyUnits: Double
        let deltaPct: Double?
        let pauseMinutes: Int?
        let episodes: HistoryBannerEpisodes?
        let pendingIsfNote: String?
        let modelCurve: [PredictionPathPoint]
        let modelMin: Double?
        let modelPeak: Double?
        let historyCurve: [PredictionPathPoint]
        let historyMin: Double?
        let historyPeak: Double?
        let historyLevel: String?

        private enum CodingKeys: String, CodingKey {
            case modelUnits, historyUnits, deltaPct, pauseMinutes, episodes, pendingIsfNote
            case modelCurve, modelMin, modelPeak, historyCurve, historyMin, historyPeak, historyLevel
        }

        init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            modelUnits = try c.decode(Double.self, forKey: .modelUnits)
            historyUnits = try c.decode(Double.self, forKey: .historyUnits)
            deltaPct = try c.decodeIfPresent(Double.self, forKey: .deltaPct)
            pauseMinutes = try c.decodeIfPresent(Int.self, forKey: .pauseMinutes)
            episodes = try? c.decodeIfPresent(HistoryBannerEpisodes.self, forKey: .episodes)
            pendingIsfNote = try c.decodeIfPresent(String.self, forKey: .pendingIsfNote)
            modelCurve = (try? c.decodeIfPresent([PredictionPathPoint].self, forKey: .modelCurve)) ?? []
            modelMin = try c.decodeIfPresent(Double.self, forKey: .modelMin)
            modelPeak = try c.decodeIfPresent(Double.self, forKey: .modelPeak)
            historyCurve = (try? c.decodeIfPresent([PredictionPathPoint].self, forKey: .historyCurve)) ?? []
            historyMin = try c.decodeIfPresent(Double.self, forKey: .historyMin)
            historyPeak = try c.decodeIfPresent(Double.self, forKey: .historyPeak)
            historyLevel = try c.decodeIfPresent(String.self, forKey: .historyLevel)
        }
    }

    /// Decodes to nil instead of failing the whole plan payload.
    struct LossyHistoryBanner: Decodable, Equatable {
        let value: HistoryBanner?
        init(value: HistoryBanner?) { self.value = value }
        init(from decoder: Decoder) throws { value = try? HistoryBanner(from: decoder) }
    }

    /// `POST /api/assistant/plans/{id}/recheck`. `level` is nil (and `curve` empty) when refused.
    struct DoseRecheck: Decodable, Equatable {
        let curve: [PredictionPathPoint]
        let min: Double?
        let level: String?
        let refusalCode: String?

        private enum CodingKeys: String, CodingKey { case curve, min, level, refusalCode }

        init(curve: [PredictionPathPoint] = [], min: Double? = nil, level: String? = nil, refusalCode: String? = nil) {
            self.curve = curve; self.min = min; self.level = level; self.refusalCode = refusalCode
        }

        init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            curve = (try? c.decodeIfPresent([PredictionPathPoint].self, forKey: .curve)) ?? []
            min = try c.decodeIfPresent(Double.self, forKey: .min)
            level = try c.decodeIfPresent(String.self, forKey: .level)
            refusalCode = try c.decodeIfPresent(String.self, forKey: .refusalCode)
        }
    }

    static func recheckPath(messageId: String) -> String {
        let id = messageId.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? messageId
        return "/api/assistant/plans/\(id)/recheck"
    }

    static func recheckBody(doseUnits: Double, clientTime: String, timezone: String) -> Data {
        let body: [String: Any] = ["doseUnits": doseUnits, "clientTime": clientTime, "timezone": timezone]
        return (try? JSONSerialization.data(withJSONObject: body)) ?? Data("{}".utf8)
    }

    static func postDoseRecheck(messageId: String, doseUnits: Double, clientTime: String,
                                timezone: String) async throws -> DoseRecheck {
        // A rejected re-check (409, 400 clock off) must never sign the user out.
        try await performWithRefresh(signOutIfUnreachable: false) {
            var req = try authorizedRequest(path: recheckPath(messageId: messageId), method: "POST")
            req.httpBody = recheckBody(doseUnits: doseUnits, clientTime: clientTime, timezone: timezone)
            let (data, resp) = try await URLSession.shared.data(for: req)
            try checkStatus(resp, data: data)
            return try GlucoseMonitorAPI.jsonDecoder().decode(DoseRecheck.self, from: data)
        }
    }
}

// MARK: - Banner answer state

/// Where the user is on a card's history banner. Nothing is preselected: `unanswered` until a dose button
/// is tapped and the re-check came back.
enum HistoryBannerState: Equatable {
    /// `notice`: why the last choice did not stick (a refusal or a failed re-check).
    case unanswered(notice: String?)
    case checking(units: Double)
    /// The re-check of `units` came back with a level. RED needs `confirmed` (second tap) before it is adopted.
    case answered(units: Double, recheck: BackendAPI.DoseRecheck, confirmed: Bool)

    static let initial = HistoryBannerState.unanswered(notice: nil)
}

enum HistoryBannerRules {

    enum Level { case ok, amber, red }

    static func level(_ recheck: BackendAPI.DoseRecheck) -> Level? {
        switch recheck.level {
        case "OK": return .ok
        case "AMBER": return .amber
        case "RED": return .red
        default: return nil
        }
    }

    /// The state after a re-check answer: a refusal, an unknown level or a missing level never adopts a dose.
    static func state(units: Double, recheck: BackendAPI.DoseRecheck) -> HistoryBannerState {
        if let code = recheck.refusalCode { return .unanswered(notice: refusalText(code, units: units)) }
        guard level(recheck) != nil else { return .unanswered(notice: "Couldn't check \(MealPlanRules.doseText(units)). Try again.") }
        return .answered(units: units, recheck: recheck, confirmed: false)
    }

    /// The dose the card adopts: OK and AMBER at once, RED only after the second tap.
    static func adoptedDose(_ state: HistoryBannerState) -> Double? {
        guard case .answered(let units, let recheck, let confirmed) = state, let level = level(recheck) else { return nil }
        return level == .red && !confirmed ? nil : units
    }

    static func confirmRed(_ state: HistoryBannerState) -> HistoryBannerState {
        guard case .answered(let units, let recheck, _) = state, level(recheck) == .red else { return state }
        return .answered(units: units, recheck: recheck, confirmed: true)
    }

    static func refusalText(_ code: String, units: Double) -> String {
        let dose = MealPlanRules.doseText(units)
        switch code {
        case "DOSE_EXCEEDS_MAX_BOLUS": return "\(dose) is above your maximum bolus. Pick a lower dose."
        case "PLAN_EXPIRED": return MealPlanRules.expiredText
        case "CGM_STALE": return MealPlanRules.staleText
        case "FORECAST_UNAVAILABLE": return "Couldn't forecast \(dose) right now. Try again, or re-plan."
        default: return MealPlanRules.refusalText(code)
        }
    }

    /// The banner a card shows: only on a PLANNED plan with a dose, not stale, not refused, not expired and
    /// without a pre-bolus in flight. Nil hides the banner and falls back to the plain plan dose.
    static func activeBanner(_ card: MealPlanCard, now: Date) -> BackendAPI.HistoryBanner? {
        guard let banner = card.payload.banner, card.payload.phase == .planned,
              let planDose = card.plan.doseUnits, planDose > 0,
              !card.plan.stale, card.plan.refusalCode == nil,
              card.plan.pause?.inFlight != true,
              !MealPlanRules.isExpired(card, now: now) else { return nil }
        return banner
    }

    /// True while a banner is on the card and no dose is adopted: the dose shows "? U" and Took is disabled.
    static func awaitingChoice(_ card: MealPlanCard, state: HistoryBannerState, now: Date) -> Bool {
        activeBanner(card, now: now) != nil && adoptedDose(state) == nil
    }

    /// The dose Took sends: the banner's adopted dose when a banner is up, else the plan's advised dose.
    static func tookDose(_ card: MealPlanCard, state: HistoryBannerState, now: Date) -> Double? {
        guard activeBanner(card, now: now) != nil else { return MealPlanRules.advisedDose(card, now: now) }
        return adoptedDose(state)
    }

    /// "Your past similar meals needed more" (or less).
    static func headline(_ banner: BackendAPI.HistoryBanner) -> String {
        "Your past similar meals needed \(banner.historyUnits >= banner.modelUnits ? "more" : "less")"
    }

    /// "Model 4.0 U \u{00B7} history 5.0 U (+25%)".
    static func comparisonLine(_ banner: BackendAPI.HistoryBanner) -> String {
        var text = "Model \(MealPlanRules.doseText(banner.modelUnits)) \u{00B7} history \(MealPlanRules.doseText(banner.historyUnits))"
        if let pct = banner.deltaPct { text += String(format: " (%+.0f%%)", pct) }
        return text
    }

    /// "3 similar meals with ~4 U peaked 11.9\u{2013}13.3, landed ~9.4 mmol/L"; nil with no episodes.
    static func episodesLine(_ banner: BackendAPI.HistoryBanner, unit: String) -> String? {
        guard let e = banner.episodes, e.count > 0 else { return nil }
        var text = "\(e.count) similar meal\(e.count == 1 ? "" : "s")"
        if let dose = e.typicalDoseUnits { text += " with ~\(ChatFormatting.backendNumber(dose)) U" }
        if let lo = e.peakLow, let hi = e.peakHigh {
            let a = ChatFormatting.glucose(mmol: lo, unit: unit), b = ChatFormatting.glucose(mmol: hi, unit: unit)
            text += " peaked \(a == b ? a : "\(a)\u{2013}\(b)")"
        }
        if let landing = e.landing {
            text += (text.contains("peaked") ? ", landed" : " landed") + " ~\(ChatFormatting.glucose(mmol: landing, unit: unit))"
        }
        return text + " " + ChatFormatting.unitLabel(unit)
    }

    /// The lowest forecast point of a re-check curve: value in mmol/L and its time.
    static func lowest(_ recheck: BackendAPI.DoseRecheck) -> (mmol: Double, at: Date?)? {
        let points = recheck.curve.compactMap { p in p.predictedGlucose.map { (mmol: $0, at: Optional(p.timestamp)) } }
        if let low = points.min(by: { $0.mmol < $1.mmol }) { return (low.mmol, low.at) }
        return recheck.min.map { ($0, nil) }
    }

    static func lowestText(_ recheck: BackendAPI.DoseRecheck, unit: String) -> String? {
        guard let low = lowest(recheck) else { return nil }
        var text = ChatFormatting.glucose(mmol: low.mmol, unit: unit)
        if let at = low.at { text += " at \(ChatFormatting.clock(at))" }
        return text
    }
}
