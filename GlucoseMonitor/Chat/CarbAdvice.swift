import Foundation

extension BackendAPI {
    /// Pre-emptive fast-carbs advice from the glucose-calculations response (`carbAdvice`).
    /// Glucose values are mmol/L. An unknown `state` fails decoding, which the response turns into nil.
    struct CarbAdvice: Decodable {
        enum State: String, Decodable { case takeNow = "TAKE_NOW", stillLanding = "STILL_LANDING" }

        let state: State
        let grams: Int?
        let minWithout: Double
        let minWithoutAt: Date
        let minWith: Double?
        let curveWithout: [PredictionPathPoint]
        let curveWith: [PredictionPathPoint]?
        let recheckAt: Date
        let landingGrams: Int?

        /// Below this (mmol/L) a STILL_LANDING card tells the user to take more.
        static let furtherCarbsThresholdMmol = 4.5

        enum CodingKeys: String, CodingKey {
            case state, grams, minWithout, minWithoutAt, minWith, curveWithout, curveWith, recheckAt, landingGrams
        }

        init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            state = try c.decode(State.self, forKey: .state)
            grams = try c.decodeIfPresent(Int.self, forKey: .grams)
            minWithout = try c.decode(Double.self, forKey: .minWithout)
            minWithoutAt = try Self.date(c, .minWithoutAt)
            minWith = try c.decodeIfPresent(Double.self, forKey: .minWith)
            curveWithout = try c.decodeIfPresent([PredictionPathPoint].self, forKey: .curveWithout) ?? []
            curveWith = try c.decodeIfPresent([PredictionPathPoint].self, forKey: .curveWith)
            recheckAt = try Self.date(c, .recheckAt)
            landingGrams = try c.decodeIfPresent(Int.self, forKey: .landingGrams)
        }

        private static func date(_ c: KeyedDecodingContainer<CodingKeys>, _ key: CodingKeys) throws -> Date {
            let s = try c.decode(String.self, forKey: key)
            guard let d = BackendAPI.parseBackendDate(s) else {
                throw DecodingError.dataCorruptedError(forKey: key, in: c, debugDescription: "Bad date: \(s)")
            }
            return d
        }

        /// The advice to show, or nil: hidden when absent, when the calculation is stale/cached,
        /// and while a low prompt is open (the hypo flow owns the screen then).
        static func visible(_ advice: CarbAdvice?, calculationsStale: Bool, calculationsFromCache: Bool = false,
                            hypoPromptOpen: Bool, now: Date = Date(),
                            tookIdentity: String? = nil) -> CarbAdvice? {
            guard let advice, !calculationsStale, !calculationsFromCache, !hypoPromptOpen else { return nil }
            guard now <= advice.recheckAt.addingTimeInterval(expiryGrace) else { return nil }
            if let tookIdentity, tookIdentity == advice.identity { return nil }
            return advice
        }

        /// Advice older than its recheck time plus this is never shown, even if no refresh arrived.
        static let expiryGrace: TimeInterval = 5 * 60

        /// Identifies one piece of advice, so "Took N g" hides it until a different one arrives.
        var identity: String {
            "\(state.rawValue)|\(Int(recheckAt.timeIntervalSince1970))|\(Int(minWithoutAt.timeIntervalSince1970))"
        }
    }
}

extension ChatFormatting {
    static func clock(_ date: Date) -> String {
        let f = DateFormatter()
        f.locale = Locale.current
        f.timeZone = TimeZone.current
        f.dateFormat = "HH:mm"
        return f.string(from: date)
    }

    static func unitLabel(_ unit: String) -> String { GlucoseUnit.isMgdl(unit) ? "mg/dL" : "mmol/L" }

    /// "Falling fast — take 15 g now" / "Wait — the 15 g is still landing. No more carbs unless under 4.5 at 19:20"
    static func carbAdviceHeadline(_ advice: BackendAPI.CarbAdvice, unit: String) -> String {
        switch advice.state {
        case .takeNow:
            return advice.grams.map { "Falling fast \u{2014} take \($0) g now" } ?? "Falling fast \u{2014} take fast carbs now"
        case .stillLanding:
            let landing = advice.landingGrams.map { "the \($0) g" } ?? "the fast carbs"
            let threshold = glucose(mmol: BackendAPI.CarbAdvice.furtherCarbsThresholdMmol, unit: unit)
            return "Wait \u{2014} \(landing) is still landing. No more carbs unless under \(threshold) at \(clock(advice.recheckAt))"
        }
    }
}
