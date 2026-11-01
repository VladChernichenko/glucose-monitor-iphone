import Foundation

// MARK: - Contract (backend Task 14/15: MealPlan, plan message payload, plan actions)

extension BackendAPI {

    /// A macro estimate with its uncertainty band, in grams.
    struct NutritionRange: Decodable, Equatable {
        let low: Double
        let mid: Double
        let high: Double
    }

    /// The pre-bolus pause chosen from the forecast. `pauseMinutes` nil = no pause advised.
    struct MealPlanPause: Decodable, Equatable {
        let pauseMinutes: Int?
        let curve: [PredictionPathPoint]
        let peak: Double?
        let min: Double?
        let reason: String?
        /// A pre-bolus is already running: no new pause was searched and no history banner is sent.
        let inFlight: Bool

        private enum CodingKeys: String, CodingKey { case pauseMinutes, curve, peak, min, reason, inFlight }

        init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            pauseMinutes = try c.decodeIfPresent(Int.self, forKey: .pauseMinutes)
            curve = try c.decodeIfPresent([PredictionPathPoint].self, forKey: .curve) ?? []
            peak = try c.decodeIfPresent(Double.self, forKey: .peak)
            min = try c.decodeIfPresent(Double.self, forKey: .min)
            reason = try c.decodeIfPresent(String.self, forKey: .reason)
            inFlight = try c.decodeIfPresent(Bool.self, forKey: .inFlight) ?? false
        }
    }

    /// The plan the backend computed. Glucose values are mmol/L. `doseUnits`/`pause` are nil when the
    /// plan is stale (no fresh CGM) or the calculator refused (`refusalCode`).
    struct MealPlan: Decodable, Equatable {
        let carbs: NutritionRange
        let fat: NutritionRange
        let protein: NutritionRange
        let fiber: NutritionRange
        let gi: Double?
        let patternLabel: String?
        let doseUnits: Double?
        let refusalCode: String?
        let pause: MealPlanPause?
        let stale: Bool
        /// After this local wall time the planned dose must not be shown or prefilled. Normally sent next to
        /// the plan (event / payload); read here too in case a backend nests it.
        let doseValidUntil: Date?

        private enum CodingKeys: String, CodingKey {
            case carbs, fat, protein, fiber, gi, patternLabel, doseUnits, refusalCode, pause, stale, doseValidUntil
        }

        init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            carbs = try c.decode(NutritionRange.self, forKey: .carbs)
            fat = try c.decode(NutritionRange.self, forKey: .fat)
            protein = try c.decode(NutritionRange.self, forKey: .protein)
            fiber = try c.decode(NutritionRange.self, forKey: .fiber)
            gi = try c.decodeIfPresent(Double.self, forKey: .gi)
            patternLabel = try c.decodeIfPresent(String.self, forKey: .patternLabel)
            doseUnits = try c.decodeIfPresent(Double.self, forKey: .doseUnits)
            refusalCode = try c.decodeIfPresent(String.self, forKey: .refusalCode)
            pause = try c.decodeIfPresent(MealPlanPause.self, forKey: .pause)
            stale = try c.decodeIfPresent(Bool.self, forKey: .stale) ?? false
            doseValidUntil = try? c.decodeIfPresent(Date.self, forKey: .doseValidUntil)
        }
    }

    /// Macros of a meal; on Eating now a nil field means "use the planned value".
    struct MealMacros: Codable, Equatable {
        var carbs: Double?
        var fat: Double?
        var protein: Double?
        var fiber: Double?
        var gi: Double?
    }

    struct MealPlanItem: Codable, Equatable {
        var name: String
        var grams: Double?
    }

    enum MealPlanPhase: String {
        case planned = "PLANNED", took = "TOOK", eaten = "EATEN", skipped = "SKIPPED"
        /// A newer plan, or insulin logged after it, replaced this PLANNED one (final; actions return 409).
        case superseded = "SUPERSEDED"
    }

    /// `payload` of a `meal_plan` chat message (history and every action response). Times are the
    /// user's local wall time.
    struct MealPlanPayload: Decodable, Equatable {
        var userMessageId: String?
        var language: String?
        var state: String
        var description: String?
        var plannedAt: Date?
        var meal: MealMacros?
        var items: [MealPlanItem]?
        var plan: MealPlan?
        var doseValidUntil: Date?
        var tookAt: Date?
        var doseUnits: Double?
        var pauseMinutes: Int?
        var eatAt: Date?
        var overdueAt: Date?
        var doseNoteId: String?
        /// "PLAN" | "USER_ENTERED".
        var doseSource: String?
        var advisedDoseUnits: Double?
        var eatenAt: Date?
        var mealNoteId: String?
        var eatenMeal: MealMacros?
        var skippedAt: Date?
        var supersededBy: String?
        /// Set instead of `supersededBy` when other rapid insulin was logged after the plan (stacking guard).
        var supersededByNoteId: String?
        var supersededAt: Date?
        /// The history banner (Task 22), absent when none was built. A malformed one is dropped, not the card.
        var bannerBox: LossyHistoryBanner?

        var banner: HistoryBanner? {
            get { bannerBox?.value }
            set { bannerBox = newValue.map { LossyHistoryBanner(value: $0) } }
        }

        private enum CodingKeys: String, CodingKey {
            case userMessageId, language, state, description, plannedAt, meal, items, plan, doseValidUntil, tookAt
            case doseUnits, pauseMinutes, eatAt, overdueAt, doseNoteId, doseSource, advisedDoseUnits, eatenAt
            case mealNoteId, eatenMeal, skippedAt, supersededBy, supersededByNoteId, supersededAt
            case bannerBox = "banner"
        }

        var phase: MealPlanPhase? { MealPlanPhase(rawValue: state) }
    }

    struct MealPlanActionResult: Decodable, Equatable {
        let messageId: String
        let state: String
        let noteId: String?
        let payload: MealPlanPayload
    }

    enum MealPlanAction: Equatable {
        case took(doseUnits: Double, pauseMinutes: Int)
        /// `ateAt`: naive local time of a late meal; nil = now.
        case eating(MealMacros, ateAt: String?)
        case skip
    }

    static func mealPlanActionPath(messageId: String, action: MealPlanAction) -> String {
        let id = messageId.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? messageId
        switch action {
        case .took: return "/api/assistant/plans/\(id)/took"
        case .eating: return "/api/assistant/plans/\(id)/eating"
        case .skip: return "/api/assistant/plans/\(id)/skip"
        }
    }

    static func mealPlanActionBody(_ action: MealPlanAction, clientTime: String, timezone: String) -> Data {
        var body: [String: Any] = ["clientTime": clientTime, "timezone": timezone]
        switch action {
        case .took(let dose, let pause):
            body["doseUnits"] = dose
            body["pauseMinutes"] = pause
        case .eating(let m, let ateAt):
            if let ateAt { body["ateAt"] = ateAt }
            // Null macros are taken from the planned meal by the backend.
            body["carbs"] = m.carbs ?? NSNull()
            body["fat"] = m.fat ?? NSNull()
            body["protein"] = m.protein ?? NSNull()
            body["fiber"] = m.fiber ?? NSNull()
            body["gi"] = m.gi ?? NSNull()
        case .skip:
            break
        }
        return (try? JSONSerialization.data(withJSONObject: body)) ?? Data("{}".utf8)
    }

    static func postMealPlanAction(messageId: String, action: MealPlanAction, clientTime: String,
                                   timezone: String) async throws -> MealPlanActionResult {
        // A rejected action (409 wrong state, 400 clock off) must never sign the user out.
        try await performWithRefresh(signOutIfUnreachable: false) {
            var req = try authorizedRequest(path: mealPlanActionPath(messageId: messageId, action: action), method: "POST")
            req.httpBody = mealPlanActionBody(action, clientTime: clientTime, timezone: timezone)
            let (data, resp) = try await URLSession.shared.data(for: req)
            try checkStatus(resp, data: data)
            return try GlucoseMonitorAPI.jsonDecoder().decode(MealPlanActionResult.self, from: data)
        }
    }
}

// MARK: - Card model

/// A plan card in the chat: the message id the action endpoints take, plus the current payload.
struct MealPlanCard: Equatable {
    let messageId: String
    var payload: BackendAPI.MealPlanPayload

    /// Nil when the payload carries no plan (nothing to render as a card).
    init?(messageId: String, payload: BackendAPI.MealPlanPayload) {
        guard payload.plan != nil else { return nil }
        self.messageId = messageId
        self.payload = payload
    }

    /// A plan that just arrived on the stream: PLANNED, nothing persisted locally yet.
    init(messageId: String, plan: BackendAPI.MealPlan, plannedAt: Date?, doseValidUntil: Date?) {
        self.messageId = messageId
        self.payload = BackendAPI.MealPlanPayload(state: BackendAPI.MealPlanPhase.planned.rawValue,
                                                  plannedAt: plannedAt, plan: plan,
                                                  doseValidUntil: doseValidUntil ?? plan.doseValidUntil)
    }

    var plan: BackendAPI.MealPlan { payload.plan! }
}

// MARK: - Display rules (pure, unit-tested)

enum MealPlanRules {

    static let overdueGrace: TimeInterval = 45 * 60
    /// The backend's dose validity (plannedAt + 15 min), used when no `doseValidUntil` was sent.
    static let doseValidity: TimeInterval = 15 * 60

    static let staleText = "No dose advice \u{2014} Libre hasn't updated recently. Check the sensor or do a fingerstick, then ask again."
    static let expiredText = "Plan expired \u{2014} re-plan for a fresh dose, or log the dose you took."

    static func refusalText(_ code: String?) -> String {
        switch code {
        case "GLUCOSE_BELOW_SAFE_THRESHOLD":
            return "No dose advice \u{2014} glucose is too low to dose for this meal. Treat the low first."
        case "DOSE_EXCEEDS_MAX_BOLUS":
            return "No dose advice \u{2014} the calculated dose is above your maximum bolus. Check the meal or your settings."
        case "SETTINGS_INVALID", "INSULIN_PARAMS_INCONSISTENT":
            return "No dose advice \u{2014} your insulin settings look incomplete. Check them in Settings."
        case "GLUCOSE_IMPLAUSIBLE_UNIT":
            return "No dose advice \u{2014} the glucose reading looks implausible. Check the sensor or do a fingerstick."
        case "FORECAST_LOW":
            return "No dose advice \u{2014} with this dose the forecast goes low. Eat or treat first, then plan again."
        default:
            return "No dose advice for this meal."
        }
    }

    /// Why a card is no longer actionable: other insulin was logged, or a newer plan exists.
    static func replacedTitle(_ p: BackendAPI.MealPlanPayload) -> String {
        p.supersededByNoteId != nil ? "Insulin logged after this plan: make a new plan" : "Replaced by a newer plan"
    }

    static func midText(_ r: BackendAPI.NutritionRange) -> String { "\(Int(r.mid.rounded())) g" }

    /// "41–50"; nil when the band rounds to a single value.
    static func rangeText(_ r: BackendAPI.NutritionRange) -> String? {
        let lo = Int(r.low.rounded()), hi = Int(r.high.rounded())
        return lo == hi ? nil : "\(lo)\u{2013}\(hi)"
    }

    static func doseText(_ units: Double) -> String { String(format: "%.1f U", units) }

    /// The plan's validity: from the payload / event, the plan itself, or plannedAt + 15 min.
    static func doseValidUntil(_ card: MealPlanCard) -> Date? {
        card.payload.doseValidUntil ?? card.plan.doseValidUntil
            ?? card.payload.plannedAt.map { $0.addingTimeInterval(doseValidity) }
    }

    /// Fails closed: with no validity and no plannedAt the dose counts as expired.
    static func isExpired(_ card: MealPlanCard, now: Date) -> Bool {
        guard card.plan.doseUnits != nil else { return false }
        guard let until = doseValidUntil(card) else { return true }
        return now > until
    }

    /// Replaced: SUPERSEDED by the server, or a PLANNED card that is not the newest plan card in the chat
    /// (only that one is actionable). TOOK and later states are never replaced.
    static func isReplaced(_ card: MealPlanCard, newestPlanId: String?) -> Bool {
        switch card.payload.phase {
        case .superseded: return true
        case .planned: return newestPlanId != nil && newestPlanId != card.messageId
        default: return false
        }
    }

    /// "Eating without insulin": any actionable PLANNED card (0 U, refused, stale or the user's choice).
    static func canEatWithoutInsulin(_ card: MealPlanCard, newestPlanId: String?) -> Bool {
        card.payload.phase == .planned && !isReplaced(card, newestPlanId: newestPlanId)
    }

    /// Earliest meal time the backend accepts: tookAt (TOOK) or plannedAt (PLANNED).
    static func ateAtLowerBound(_ p: BackendAPI.MealPlanPayload) -> Date? {
        p.phase == .took ? p.tookAt : p.plannedAt
    }

    /// The late-meal default: when the meal was due (eatAt), never after now.
    static func lateMealDefault(_ p: BackendAPI.MealPlanPayload, now: Date) -> Date {
        min(eatAt(p) ?? now, now)
    }

    /// What to send as `ateAt` for a picked time: clamped up to `lower` (the picker has minute
    /// resolution); nil within a minute of now or in the future, so the server uses its own now and a
    /// slightly fast phone clock never trips the "in the future" check.
    static func ateAtToSend(picked: Date, lower: Date?, now: Date) -> Date? {
        let t = lower.map { max(picked, $0) } ?? picked
        return now.timeIntervalSince(t) < 60 ? nil : t
    }

    /// The calculator dose to show and prefill; nil when stale, refused or expired.
    static func advisedDose(_ card: MealPlanCard, now: Date) -> Double? {
        let plan = card.plan
        guard !plan.stale, plan.refusalCode == nil, let dose = plan.doseUnits, !isExpired(card, now: now) else { return nil }
        return dose
    }

    /// "Took it" sends the advised dose; the backend needs doseUnits > 0.
    static func canTakeAdvised(_ card: MealPlanCard, now: Date) -> Bool {
        (advisedDose(card, now: now) ?? 0) > 0
    }

    /// Pause shown only alongside an advised dose, and only when the backend chose one.
    static func advisedPause(_ card: MealPlanCard, now: Date) -> Int? {
        guard advisedDose(card, now: now) != nil else { return nil }
        return card.plan.pause?.pauseMinutes
    }

    /// Why no dose is shown, or nil when a dose is advised.
    static func noDoseExplanation(_ card: MealPlanCard, now: Date, unit: String = "mmol/L") -> String? {
        let plan = card.plan
        if plan.stale { return staleText }
        if plan.refusalCode == "FORECAST_LOW", let low = plan.pause?.min { return forecastLowText(low, unit: unit) }
        if plan.refusalCode != nil || plan.doseUnits == nil { return refusalText(plan.refusalCode) }
        if isExpired(card, now: now) { return expiredText }
        return nil
    }

    /// The low line the backend withholds a dose at (HypoThresholds.HYPO_MMOL).
    static let hypoMmol = 3.9

    /// A dose withheld because, with insulin already on board, its forecast falls below the low line.
    static func forecastLowText(_ lowestMmol: Double, unit: String) -> String {
        let low = ChatFormatting.glucose(mmol: lowestMmol, unit: unit)
        let line = ChatFormatting.glucose(mmol: hypoMmol, unit: unit)
        return "No dose advice \u{2014} with this dose the forecast drops to \(low) \(ChatFormatting.unitLabel(unit)), "
            + "below \(line). Eat or treat first, then plan again."
    }

    static func peakLine(_ pause: BackendAPI.MealPlanPause, unit: String) -> String? {
        var parts: [String] = []
        if let peak = pause.peak { parts.append("Peak ~\(ChatFormatting.glucose(mmol: peak, unit: unit))") }
        if let min = pause.min { parts.append("lowest \(ChatFormatting.glucose(mmol: min, unit: unit))") }
        guard !parts.isEmpty else { return nil }
        return parts.joined(separator: " \u{00B7} ") + " " + ChatFormatting.unitLabel(unit)
    }

    /// "4.5 U taken 12:31", plus "logged, not advised" for a dose the user typed.
    static func dosedLabel(_ p: BackendAPI.MealPlanPayload) -> String {
        var text = p.doseUnits.map(doseText) ?? "Dose"
        text += " taken"
        if let tookAt = p.tookAt { text += " \(ChatFormatting.clock(tookAt))" }
        if p.doseSource == "USER_ENTERED" { text += " \u{00B7} logged, not advised" }
        return text
    }

    static func eatAt(_ p: BackendAPI.MealPlanPayload) -> Date? {
        if let eatAt = p.eatAt { return eatAt }
        return p.tookAt.map { $0.addingTimeInterval(TimeInterval((p.pauseMinutes ?? 0) * 60)) }
    }

    /// "06:42" until the meal; nil once it is time to eat (the card then says Eating now).
    static func countdown(_ p: BackendAPI.MealPlanPayload, now: Date) -> String? {
        guard p.phase == .took, let eatAt = eatAt(p) else { return nil }
        return PreBolusTimer.countdownLabel(until: eatAt, now: now)
    }

    /// Amber: dose taken, meal not logged, and now past tookAt + pause + 45 min.
    static func isOverdue(_ p: BackendAPI.MealPlanPayload, now: Date) -> Bool {
        guard p.phase == .took else { return false }
        if let eatAt = eatAt(p) { return now > eatAt.addingTimeInterval(overdueGrace) }
        return p.overdueAt.map { now > $0 } ?? false
    }

    /// Edit re-plans through the chat (there is no re-plan endpoint): "prepare me for: rye bread 40 g, soup".
    static func replanMessage(_ items: [BackendAPI.MealPlanItem]) -> String {
        let parts = items.compactMap { item -> String? in
            let name = item.name.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !name.isEmpty else { return nil }
            guard let g = item.grams, g > 0 else { return name }
            return "\(name) \(ChatFormatting.backendNumber(g)) g"
        }
        return "prepare me for: " + parts.joined(separator: ", ")
    }

    enum ActionFailure: Equatable {
        /// 409: the message moved on elsewhere (or a double tap); refresh, no error.
        case conflict
        /// 4xx with the server's own message (e.g. the phone clock is off, dose above max bolus).
        case rejected(String)
        case failed(String)
    }

    static func classify(_ error: Error) -> ActionFailure {
        if case GlucoseMonitorAPI.APIError.httpStatus(let code, let body) = error {
            if code == 409 { return .conflict }
            if (400..<500).contains(code), let message = serverMessage(body) { return .rejected(withClockHint(message)) }
        }
        return .failed("Couldn't save. \(error.localizedDescription)")
    }

    static let clockHint = "Turn on Settings \u{203A} General \u{203A} Date & Time \u{203A} Set Automatically, then try again."

    /// The server rejects a phone clock off by more than +2/-10 min ("Your phone's clock is off: ...").
    static func withClockHint(_ message: String) -> String {
        message.localizedCaseInsensitiveContains("clock is off") ? message + " " + clockHint : message
    }

    /// The server's own reason for a 4xx (its `message` field), or nil.
    static func serverRejection(_ error: Error) -> String? {
        if case .rejected(let message) = classify(error) { return message }
        return nil
    }

    private static func serverMessage(_ body: String?) -> String? {
        guard let data = body?.data(using: .utf8),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let message = obj["message"] as? String, !message.isEmpty else { return nil }
        return message
    }
}
