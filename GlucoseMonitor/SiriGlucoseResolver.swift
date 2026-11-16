import Foundation

/// Where Siri's reading comes from. Closures so the decision logic can be tested without network or storage.
struct SiriReadingSource {
    var loadCached: () -> SiriGlucoseReading?
    var fetchLatest: () async throws -> SiriGlucoseReading?
    var storeFetched: (SiriGlucoseReading) -> Void
}

/// Cache first, live fetch (bounded by a timeout) second, cache again if the fetch fails.
enum SiriGlucoseResolver {
    /// Siri expects a quick answer; past this the cached reading is spoken with its age instead.
    static let fetchTimeout: TimeInterval = 4

    static func resolve(
        _ source: SiriReadingSource,
        now: Date = Date(),
        timeout: TimeInterval = fetchTimeout
    ) async -> SiriGlucoseReading? {
        let cached = source.loadCached()
        if let cached, SiriGlucoseAnswer.isCacheFresh(cached, now: now) { return cached }

        guard let fetched = await fetch(source, timeout: timeout) else { return cached }
        // Never replace a newer cached reading with an older one.
        if let cached, fetched.time <= cached.time { return cached }

        source.storeFetched(fetched)
        return fetched
    }

    /// Races the fetch against a timer. A failed, empty or too-slow fetch is `nil`.
    private static func fetch(_ source: SiriReadingSource, timeout: TimeInterval) async -> SiriGlucoseReading? {
        await withTaskGroup(of: SiriGlucoseReading?.self) { group in
            group.addTask { try? await source.fetchLatest() }
            group.addTask {
                try? await Task.sleep(nanoseconds: UInt64(timeout * 1_000_000_000))
                return nil
            }
            let first = await group.next() ?? nil
            group.cancelAll()
            return first
        }
    }
}
