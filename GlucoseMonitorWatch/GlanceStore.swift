import Foundation

/// The latest glance, in the watch's App Group, so the complication can draw it without the network.
enum GlanceStore {

    static let key = "gm_watch_glance_v1"

    private struct Stored: Codable {
        let glance: WatchGlance
        let fetchedAt: Date
    }

    static func save(_ glance: WatchGlance, fetchedAt: Date) {
        guard let data = try? JSONEncoder().encode(Stored(glance: glance, fetchedAt: fetchedAt)) else { return }
        GlucoseMonitorAPI.sharedDefaults().set(data, forKey: key)
    }

    static func load() -> (glance: WatchGlance, fetchedAt: Date)? {
        guard let data = GlucoseMonitorAPI.sharedDefaults().data(forKey: key),
              let stored = try? JSONDecoder().decode(Stored.self, from: data) else { return nil }
        return (stored.glance, stored.fetchedAt)
    }

    static func clear() {
        GlucoseMonitorAPI.sharedDefaults().removeObject(forKey: key)
    }
}
