import Foundation

// The strip model and its text live in Shared/WatchStripModel.swift (shared with the Apple Watch).

extension AppState {
    /// Older than this, the last successful calculations fetch is too old to act on.
    static let watchStripMaxAge: TimeInterval = 600

    /// The watch strip to show now.
    var visibleWatchStrip: WatchStrip? { watchStrip(at: Date()) }

    /// The watch strip to show at `now`, or nil: hidden when the data behind it is stale, restored from cache
    /// or more than `watchStripMaxAge` old, when the backend sent none, and when this app version can't
    /// phrase it. A dose or carbs suggestion is also hidden once its recheck time has passed: an old
    /// "take 1 U" must never stay on screen.
    func watchStrip(at now: Date) -> WatchStrip? {
        guard !libreDataStale, !calculationsStale, !calculationsFromCache,
              let fetchedAt = calculationsFetchedAt, now.timeIntervalSince(fetchedAt) <= Self.watchStripMaxAge,
              let strip = calculations?.watch, strip.isKnown else { return nil }
        if strip.suggestionExpired(at: now) { return nil }
        return strip
    }
}
