import Foundation

/// `GET /api/watch/glance`: everything the Apple Watch shows, in one response. Field names match the
/// backend's `WatchGlance` record.
struct WatchGlance: Codable, Equatable {

    struct Reading: Codable, Equatable {
        /// sgv / 18.018, the phone's conversion.
        let mmol: Double
        /// Sent as epoch milliseconds.
        let at: Date
        /// LibreLinkUp TrendArrow 1-5, as stored.
        let trend: Int?
        /// Nightscout direction, as stored.
        let direction: String?
        /// The user reads from LibreLinkUp (the arrow then comes from `trend`).
        let libre: Bool

        enum CodingKeys: String, CodingKey { case mmol, at, trend, direction, libre }

        init(mmol: Double, at: Date, trend: Int?, direction: String?, libre: Bool) {
            self.mmol = mmol
            self.at = at
            self.trend = trend
            self.direction = direction
            self.libre = libre
        }

        init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            mmol = try c.decode(Double.self, forKey: .mmol)
            at = Date(timeIntervalSince1970: try c.decode(Double.self, forKey: .at) / 1000)
            trend = try c.decodeIfPresent(Int.self, forKey: .trend)
            direction = try c.decodeIfPresent(String.self, forKey: .direction)
            libre = try c.decode(Bool.self, forKey: .libre)
        }

        func encode(to encoder: Encoder) throws {
            var c = encoder.container(keyedBy: CodingKeys.self)
            try c.encode(mmol, forKey: .mmol)
            try c.encode((at.timeIntervalSince1970 * 1000).rounded(), forKey: .at)
            try c.encode(trend, forKey: .trend)
            try c.encode(direction, forKey: .direction)
            try c.encode(libre, forKey: .libre)
        }

        /// The arrow the phone would show for this reading.
        var arrow: String { TrendArrow.arrow(trend: trend, direction: direction, libreEntry: libre) }
    }

    enum StaleCause: String, Codable {
        case none = "NONE", upstreamDown = "UPSTREAM_DOWN", noNewReadings = "NO_NEW_READINGS"
        /// A cause this app version doesn't know: treated as stale, with no banner text and no wrist tap.
        case unknown = "UNKNOWN"
        init(from decoder: Decoder) throws {
            self = Self(rawValue: try decoder.singleValueContainer().decode(String.self)) ?? .unknown
        }
    }

    let reading: Reading?
    let staleCause: StaleCause
    let twoHourPredictionMmol: Double?
    let watch: WatchStrip?
}

extension WatchGlance {
    /// Lenient, like the phone's `watch` decoding: one malformed field is dropped instead of blanking the glance.
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        reading = (try? c.decodeIfPresent(Reading.self, forKey: .reading)) ?? nil
        staleCause = (try? c.decodeIfPresent(StaleCause.self, forKey: .staleCause)) ?? .unknown
        twoHourPredictionMmol = (try? c.decodeIfPresent(Double.self, forKey: .twoHourPredictionMmol)) ?? nil
        watch = (try? c.decodeIfPresent(WatchStrip.self, forKey: .watch)) ?? nil
    }
}
