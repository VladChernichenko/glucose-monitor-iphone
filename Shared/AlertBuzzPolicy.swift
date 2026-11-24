import Foundation

/// What the Apple Watch remembers between glances to tap the wrist once per alert.
struct BuzzMemory: Codable, Equatable {
    /// The alert last tapped for ("URGENT_LOW/LOW_NOW", "stale/UPSTREAM_DOWN"); nil when none is on.
    var lastKey: String?
    /// The recheck time of the last LOW_NOW tap: still low at or after it taps again.
    var lastRecheckAt: Date?
    /// When the previous glance was decided on.
    var lastGlanceAt: Date?

    init(lastKey: String? = nil, lastRecheckAt: Date? = nil, lastGlanceAt: Date? = nil) {
        self.lastKey = lastKey
        self.lastRecheckAt = lastRecheckAt
        self.lastGlanceAt = lastGlanceAt
    }
}

/// A wrist tap: the phone banner's two lines.
struct Buzz: Equatable {
    let title: String
    let body: String
}

/// Taps only for alerts that need the user to act (the user's decision, 2026-11-24): Low now, Low likely,
/// High ahead, and Libre going stale. Everything else on the watch is show-only.
enum AlertBuzzPolicy {

    static let buzzingReasons: Set<WatchStrip.Reason> = [.lowNow, .forecastLow, .highForecast]
    /// After a gap this long, an alert already past its recheck time is old news: no tap.
    static let longGap: TimeInterval = 30 * 60

    static func decide(memory: BuzzMemory, glance: WatchGlance, now: Date, unit: String) -> (buzz: Buzz?, memory: BuzzMemory) {
        var next = memory
        next.lastGlanceAt = now
        let afterLongGap = memory.lastGlanceAt.map { now.timeIntervalSince($0) > longGap } ?? true

        // A stale glance never taps for its strip: the strip was not computed from a current reading.
        if let cause = LibreStaleCause(glance.staleCause) {
            let key = "stale/\(glance.staleCause.rawValue)"
            next.lastRecheckAt = nil
            guard key != memory.lastKey else { return (nil, next) }
            next.lastKey = key
            return (Buzz(title: cause.title, body: cause.detail(lastReading: glance.reading?.at, now: now)), next)
        }

        guard let strip = glance.watch, strip.isKnown, buzzingReasons.contains(strip.reason) else {
            next.lastKey = nil
            next.lastRecheckAt = nil
            return (nil, next)
        }
        let key = "\(strip.state.rawValue)/\(strip.reason.rawValue)"
        let isNew = key != memory.lastKey
        let recheckDue = strip.reason == .lowNow && memory.lastRecheckAt.map { now >= $0 } == true
        guard isNew || recheckDue else { return (nil, next) }
        if afterLongGap && strip.nextCheckAt < now {
            next.lastKey = key
            return (nil, next)
        }
        next.lastKey = key
        next.lastRecheckAt = strip.reason == .lowNow ? strip.nextCheckAt : nil
        return (Buzz(title: WatchStripText.headline(strip, unit: unit), body: WatchStripText.detail(strip, unit: unit)), next)
    }
}
