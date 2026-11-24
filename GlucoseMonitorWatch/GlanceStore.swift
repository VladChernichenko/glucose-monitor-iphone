import Foundation

/// The latest glance, in the watch's App Group, so the complication can draw it without the network.
enum GlanceStore {

    static let key = "gm_watch_glance_v1"
    /// When the latest refresh failed; cleared by the next successful one.
    static let failedKey = "gm_watch_glance_failed_at_v1"

    private struct Stored: Codable {
        let glance: WatchGlance
        let fetchedAt: Date
    }

    static func save(_ glance: WatchGlance, fetchedAt: Date) {
        guard let data = try? JSONEncoder().encode(Stored(glance: glance, fetchedAt: fetchedAt)) else { return }
        let ud = GlucoseMonitorAPI.sharedDefaults()
        ud.set(data, forKey: key)
        ud.removeObject(forKey: failedKey)
    }

    /// The phone hides its strip as soon as a refresh fails; the watch and complication read this to do the same.
    static func recordFailure(at date: Date = Date()) {
        GlucoseMonitorAPI.sharedDefaults().set(date, forKey: failedKey)
    }

    static func lastAttemptFailed() -> Bool {
        GlucoseMonitorAPI.sharedDefaults().object(forKey: failedKey) != nil
    }

    static func load() -> (glance: WatchGlance, fetchedAt: Date)? {
        guard let data = GlucoseMonitorAPI.sharedDefaults().data(forKey: key),
              let stored = try? JSONDecoder().decode(Stored.self, from: data) else { return nil }
        return (stored.glance, stored.fetchedAt)
    }

    static func clear() {
        let ud = GlucoseMonitorAPI.sharedDefaults()
        ud.removeObject(forKey: key)
        ud.removeObject(forKey: failedKey)
    }
}
