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

        guard var fetched = await fetch(source, timeout: timeout) else { return cached }
        if let cached {
            // Never replace a newer cached reading with an older one.
            if fetched.time < cached.time { return cached }
            // Same sample time: the cached value may be a fingerstick dated with the CGM time, so the
            // backend's CGM value is the authority. Whether the source is flagged stale is the app's call.
            if fetched.time == cached.time { fetched.flaggedStale = cached.flaggedStale }
            if fetched == cached { return cached }
        }

        source.storeFetched(fetched)
        return fetched
    }

    /// Races the fetch against a timer. A failed, empty or too-slow fetch is `nil`.
    /// Not a task group: a group waits for every child, and the token-refresh path inside a fetch ignores
    /// cancellation, so a slow refresh would hold Siri far past the timeout. Here the first result wins and
    /// the loser is simply abandoned (cancelled, its late result discarded).
    private static func fetch(_ source: SiriReadingSource, timeout: TimeInterval) async -> SiriGlucoseReading? {
        await withCheckedContinuation { continuation in
            let race = FetchRace(continuation)
            race.track(Task { race.finish(try? await source.fetchLatest()) })
            race.track(Task {
                try? await Task.sleep(nanoseconds: UInt64(timeout * 1_000_000_000))
                race.finish(nil)
            })
        }
    }
}

/// Resumes its continuation exactly once, with whichever result arrives first, and cancels the other task.
private final class FetchRace {
    private let lock = NSLock()
    private var continuation: CheckedContinuation<SiriGlucoseReading?, Never>?
    private var tasks: [Task<Void, Never>] = []

    init(_ continuation: CheckedContinuation<SiriGlucoseReading?, Never>) {
        self.continuation = continuation
    }

    func track(_ task: Task<Void, Never>) {
        lock.lock()
        let alreadyFinished = continuation == nil
        if !alreadyFinished { tasks.append(task) }
        lock.unlock()
        if alreadyFinished { task.cancel() }
    }

    func finish(_ value: SiriGlucoseReading?) {
        lock.lock()
        guard let continuation else { lock.unlock(); return }
        self.continuation = nil
        let toCancel = tasks
        tasks = []
        lock.unlock()
        toCancel.forEach { $0.cancel() }
        continuation.resume(returning: value)
    }
}
