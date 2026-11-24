import Foundation

/// What the Apple Watch remembers between glances to tap the wrist once per alert.
struct BuzzMemory: Codable, Equatable {
    /// The alert last tapped for ("URGENT_LOW/LOW_NOW", "stale/UPSTREAM_DOWN"); nil when none is on.
    var lastKey: String?
    /// The recheck time of the last LOW_NOW tap: still low at or after it taps again.
    var lastRecheckAt: Date?
    /// When the previous glance was decided on.
    var lastGlanceAt: Date?
    /// The alert whose notification is still in Notification Center, and until when its advice holds.
    var deliveredKey: String?
    var deliveredUntil: Date?

    init(lastKey: String? = nil, lastRecheckAt: Date? = nil, lastGlanceAt: Date? = nil,
         deliveredKey: String? = nil, deliveredUntil: Date? = nil) {
        self.lastKey = lastKey
        self.lastRecheckAt = lastRecheckAt
        self.lastGlanceAt = lastGlanceAt
        self.deliveredKey = deliveredKey
        self.deliveredUntil = deliveredUntil
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

    /// - Returns: the tap to post (if any), the memory to keep, and whether the notification already in
    ///   Notification Center must be removed: its alert ended, or its advice passed its recheck time.
    static func decide(memory: BuzzMemory, glance: WatchGlance, now: Date, unit: String)
        -> (buzz: Buzz?, memory: BuzzMemory, clearDelivered: Bool) {
        var next = memory
        next.lastGlanceAt = now
        let afterLongGap = memory.lastGlanceAt.map { now.timeIntervalSince($0) > longGap } ?? true

        let staleCause = LibreStaleCause(glance.staleCause)
        let strip = glance.staleCause == .none ? glance.watch.flatMap { s in
            s.isKnown && buzzingReasons.contains(s.reason) ? s : nil
        } : nil
        let currentKey: String? = staleCause != nil ? "stale/\(glance.staleCause.rawValue)"
            : strip.map { "\($0.state.rawValue)/\($0.reason.rawValue)" }

        var clearDelivered = false
        if let delivered = memory.deliveredKey,
           currentKey != delivered || memory.deliveredUntil.map({ now >= $0 }) == true {
            clearDelivered = true
            next.deliveredKey = nil
            next.deliveredUntil = nil
        }

        // A stale glance never taps for its strip: the strip was not computed from a current reading.
        if let cause = staleCause, let key = currentKey {
            next.lastRecheckAt = nil
            guard key != memory.lastKey else { return (nil, next, clearDelivered) }
            next.lastKey = key
            next.deliveredKey = key
            next.deliveredUntil = nil
            return (Buzz(title: cause.title, body: cause.detail(lastReading: glance.reading?.at, now: now)),
                    next, clearDelivered)
        }
        // An unknown stale cause: stale, but nothing to say and no strip to trust.
        if glance.staleCause != .none {
            return (nil, next, clearDelivered)
        }

        guard let strip, let key = currentKey else {
            next.lastKey = nil
            next.lastRecheckAt = nil
            return (nil, next, clearDelivered)
        }
        let isNew = key != memory.lastKey
        let recheckDue = strip.reason == .lowNow && memory.lastRecheckAt.map { now >= $0 } == true
        guard isNew || recheckDue else { return (nil, next, clearDelivered) }
        next.lastKey = key
        next.lastRecheckAt = strip.reason == .lowNow ? strip.nextCheckAt : nil
        if afterLongGap && strip.nextCheckAt < now {
            // Old news after a long gap: no tap, but the recheck clock above keeps running.
            return (nil, next, clearDelivered)
        }
        next.deliveredKey = key
        next.deliveredUntil = strip.nextCheckAt
        return (Buzz(title: WatchStripText.headline(strip, unit: unit), body: WatchStripText.detail(strip, unit: unit)),
                next, clearDelivered)
    }
}
