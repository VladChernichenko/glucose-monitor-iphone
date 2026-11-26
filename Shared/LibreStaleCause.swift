import Foundation

/// Why the dashboard (or the watch) is not showing the readings as current.
enum LibreStaleCause: Equatable {
    /// LibreLinkUp is not answering (the backend's circuit breaker is open).
    case upstreamDown
    /// LibreLinkUp answers, but no reading newer than 15 min has arrived.
    case noNewReadings
    /// LibreLinkUp rejected the saved email/password; the sync is paused until they are entered again.
    case credentialsRejected

    /// The watch glance's cause; nil when the glance says the readings are current.
    init?(_ cause: WatchGlance.StaleCause) {
        switch cause {
        case .none, .unknown: return nil
        case .upstreamDown: self = .upstreamDown
        case .noNewReadings: self = .noNewReadings
        }
    }

    var title: String {
        switch self {
        case .upstreamDown: return "LibreLinkUp isn't responding"
        case .noNewReadings: return "No new readings from Libre"
        case .credentialsRejected: return "LibreLinkUp password not accepted"
        }
    }

    /// True when the user has to act in Settings (the banner then opens it on tap).
    var needsSettings: Bool { self == .credentialsRejected }

    /// The banner's second line; `lastReading` is the newest reading's time, nil when unknown.
    func detail(lastReading: Date?, now: Date = Date()) -> String {
        let since = lastReading.map { " for " + Self.span(now.timeIntervalSince($0)) } ?? ""
        switch self {
        case .upstreamDown:
            return "Data is stale\(lastReading == nil ? "" : " - no update" + since). Reconnecting..."
        case .noNewReadings:
            return "Nothing new" + since + ". Check the sensor and the Libre app on your phone."
        case .credentialsRejected:
            return "Syncing is paused. Tap to enter your LibreLinkUp email and password again in Settings."
        }
    }

    /// "55 min", "1 h 20 min".
    static func span(_ seconds: TimeInterval) -> String {
        let minutes = max(0, Int(seconds / 60))
        if minutes < 60 { return "\(minutes) min" }
        let rest = minutes % 60
        return rest == 0 ? "\(minutes / 60) h" : "\(minutes / 60) h \(rest) min"
    }
}
