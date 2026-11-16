import XCTest
@testable import GlucoseMonitor

/// Pins the cache-first / live-fallback decision behind "Hey Siri, what is my blood sugar".
final class SiriGlucoseResolverTests: XCTestCase {

    private struct FetchFailure: Error {}

    private let now = Date(timeIntervalSince1970: 1_800_000_000)

    private func reading(mmol: Double, ageMinutes: Double, flaggedStale: Bool = false) -> SiriGlucoseReading {
        SiriGlucoseReading(
            mmol: mmol,
            time: now.addingTimeInterval(-ageMinutes * 60),
            deltaMmol: nil,
            trendArrow: nil,
            flaggedStale: flaggedStale
        )
    }

    /// Records how the resolver used its source.
    private final class Calls {
        var fetches = 0
        var stored: [SiriGlucoseReading] = []
    }

    private func source(
        cached: SiriGlucoseReading?,
        calls: Calls,
        fetch: @escaping () async throws -> SiriGlucoseReading?
    ) -> SiriReadingSource {
        SiriReadingSource(
            loadCached: { cached },
            fetchLatest: { calls.fetches += 1; return try await fetch() },
            storeFetched: { calls.stored.append($0) }
        )
    }

    func testFreshCacheDoesNotFetch() async {
        let calls = Calls()
        let cached = reading(mmol: 5.6, ageMinutes: 2)
        let result = await SiriGlucoseResolver.resolve(
            source(cached: cached, calls: calls) { self.reading(mmol: 9.9, ageMinutes: 0) },
            now: now
        )
        XCTAssertEqual(result, cached)
        XCTAssertEqual(calls.fetches, 0)
        XCTAssertTrue(calls.stored.isEmpty)
    }

    func testStaleCacheFetchesAndStores() async {
        let calls = Calls()
        let fetched = reading(mmol: 7.1, ageMinutes: 1)
        let result = await SiriGlucoseResolver.resolve(
            source(cached: reading(mmol: 5.6, ageMinutes: 10), calls: calls) { fetched },
            now: now
        )
        XCTAssertEqual(result, fetched)
        XCTAssertEqual(calls.fetches, 1)
        XCTAssertEqual(calls.stored, [fetched])
    }

    func testNoCacheFetches() async {
        let calls = Calls()
        let fetched = reading(mmol: 7.1, ageMinutes: 1)
        let result = await SiriGlucoseResolver.resolve(
            source(cached: nil, calls: calls) { fetched },
            now: now
        )
        XCTAssertEqual(result, fetched)
        XCTAssertEqual(calls.stored, [fetched])
    }

    func testFetchThrowsReturnsCache() async {
        let calls = Calls()
        let cached = reading(mmol: 5.6, ageMinutes: 10)
        let result = await SiriGlucoseResolver.resolve(
            source(cached: cached, calls: calls) { throw FetchFailure() },
            now: now
        )
        XCTAssertEqual(result, cached)
        XCTAssertTrue(calls.stored.isEmpty)
    }

    /// Backend answered but had no usable readings: fall back, never invent a value.
    func testFetchNilReturnsCache() async {
        let calls = Calls()
        let cached = reading(mmol: 5.6, ageMinutes: 10)
        let result = await SiriGlucoseResolver.resolve(
            source(cached: cached, calls: calls) { () -> SiriGlucoseReading? in nil },
            now: now
        )
        XCTAssertEqual(result, cached)
        XCTAssertTrue(calls.stored.isEmpty)
    }

    func testNoCacheAndFetchFailsReturnsNil() async {
        let calls = Calls()
        let result = await SiriGlucoseResolver.resolve(
            source(cached: nil, calls: calls) { throw FetchFailure() },
            now: now
        )
        XCTAssertNil(result)
    }

    func testFetchedOlderThanCacheKeepsCache() async {
        let calls = Calls()
        let cached = reading(mmol: 5.6, ageMinutes: 10)
        let older = reading(mmol: 4.0, ageMinutes: 11)
        let result = await SiriGlucoseResolver.resolve(
            source(cached: cached, calls: calls) { older },
            now: now
        )
        XCTAssertEqual(result, cached)
        XCTAssertTrue(calls.stored.isEmpty)
    }

    func testSlowFetchTimesOutToCache() async {
        let calls = Calls()
        let cached = reading(mmol: 5.6, ageMinutes: 10)
        let started = Date()
        let result = await SiriGlucoseResolver.resolve(
            source(cached: cached, calls: calls) {
                try await Task.sleep(nanoseconds: 2_000_000_000)
                return self.reading(mmol: 7.1, ageMinutes: 0)
            },
            now: now,
            timeout: 0.05
        )
        XCTAssertEqual(result, cached)
        XCTAssertLessThan(Date().timeIntervalSince(started), 0.5)
        XCTAssertTrue(calls.stored.isEmpty)
    }

    /// The token-refresh path awaits an unstructured task, which ignores cancellation: the timeout must
    /// still return on time, and the late result must be discarded, not stored.
    func testNonCancellableFetchStillTimesOut() async {
        let calls = Calls()
        let cached = reading(mmol: 5.6, ageMinutes: 10)
        let started = Date()
        let result = await SiriGlucoseResolver.resolve(
            source(cached: cached, calls: calls) {
                await Task.detached { try? await Task.sleep(nanoseconds: 1_500_000_000) }.value
                return self.reading(mmol: 7.1, ageMinutes: 0)
            },
            now: now,
            timeout: 0.05
        )
        XCTAssertEqual(result, cached)
        XCTAssertLessThan(Date().timeIntervalSince(started), 0.5)
        XCTAssertTrue(calls.stored.isEmpty)
    }

    /// The cached value may be a fingerstick dated with the CGM time; the backend's CGM value at the
    /// same sample time is the authority, and the app's "source is stale" flag is kept.
    func testFetchedWithSameTimeAsCacheReplacesValueAndKeepsStaleFlag() async {
        let calls = Calls()
        let cached = reading(mmol: 8.0, ageMinutes: 10, flaggedStale: true)
        let fetched = reading(mmol: 5.6, ageMinutes: 10)
        let result = await SiriGlucoseResolver.resolve(
            source(cached: cached, calls: calls) { fetched },
            now: now
        )
        XCTAssertEqual(result?.mmol, 5.6)
        XCTAssertEqual(result?.flaggedStale, true)
        XCTAssertEqual(calls.stored.count, 1)
        XCTAssertEqual(calls.stored.first, result)
    }

    func testDefaultTimeoutIsFourSeconds() {
        XCTAssertEqual(SiriGlucoseResolver.fetchTimeout, 4)
    }
}
