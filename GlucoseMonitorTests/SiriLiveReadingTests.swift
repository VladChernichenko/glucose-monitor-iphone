import XCTest
@testable import GlucoseMonitor

/// Pins how backend entries and the widget snapshot become Siri readings, and how a fetched reading
/// is merged back into the snapshot without wiping the widget's other data.
final class SiriLiveReadingTests: XCTestCase {

    private let t0 = Date(timeIntervalSince1970: 1_800_000_000)

    private func entry(sgv: Double?, at date: Date, type: String? = "sgv", trend: Int? = 3) throws -> BackendAPI.NightscoutEntry {
        var dict: [String: Any] = ["date": Int64(date.timeIntervalSince1970 * 1000)]
        if let sgv { dict["sgv"] = sgv }
        if let type { dict["type"] = type }
        if let trend { dict["trend"] = trend }
        let data = try JSONSerialization.data(withJSONObject: dict)
        return try JSONDecoder().decode(BackendAPI.NightscoutEntry.self, from: data)
    }

    private func snapshot(
        value: Double?, unit: String = "mmol/L", delta: Double? = nil, savedAt: Date? = nil, dataStale: Bool? = nil
    ) -> LockScreenWidgetSnapshot {
        LockScreenWidgetSnapshot(
            savedAt: savedAt ?? t0,
            glucoseValue: value,
            glucoseUnit: unit,
            trendArrow: "\u{2192}",
            deltaValue: delta,
            cobGrams: 12,
            iobUnits: 1.5,
            twoHourPredictionMmol: 6.2,
            chartPoints: [.init(time: t0, mmol: 5.0)],
            dataStale: dataStale
        )
    }

    // MARK: latest(from:isLLU:)

    func testLatestPicksNewestSgvRegardlessOfOrder() throws {
        let entries = [
            try entry(sgv: 108, at: t0.addingTimeInterval(-600)),
            try entry(sgv: 101, at: t0),
            try entry(sgv: 95, at: t0.addingTimeInterval(-300)),
        ]
        let r = try XCTUnwrap(SiriLiveReading.latest(from: entries, isLLU: true))
        XCTAssertEqual(r.mmol, 101 / 18.018, accuracy: 0.01)
        XCTAssertEqual(r.time, t0)
        XCTAssertFalse(r.flaggedStale)
    }

    func testLatestIgnoresNonSgvTypes() throws {
        let entries = [
            try entry(sgv: 101, at: t0.addingTimeInterval(-300)),
            try entry(sgv: 250, at: t0, type: "mbg"),
        ]
        let r = try XCTUnwrap(SiriLiveReading.latest(from: entries, isLLU: true))
        XCTAssertEqual(r.mmol, 101 / 18.018, accuracy: 0.01)
    }

    /// A newer entry with no value must not hide an older usable one, and must never become "0".
    func testLatestSkipsEntriesWithoutSgv() throws {
        let entries = [
            try entry(sgv: 101, at: t0.addingTimeInterval(-300)),
            try entry(sgv: nil, at: t0),
        ]
        let r = try XCTUnwrap(SiriLiveReading.latest(from: entries, isLLU: true))
        XCTAssertEqual(r.time, t0.addingTimeInterval(-300))
    }

    func testLatestDeltaIsNewestMinusPreviousInMmol() throws {
        let entries = [
            try entry(sgv: 100, at: t0.addingTimeInterval(-300)),
            try entry(sgv: 109, at: t0),
        ]
        let r = try XCTUnwrap(SiriLiveReading.latest(from: entries, isLLU: true))
        XCTAssertEqual(try XCTUnwrap(r.deltaMmol), 9 / 18.018, accuracy: 0.01)
    }

    func testLatestSingleEntryHasNoDelta() throws {
        let r = try XCTUnwrap(SiriLiveReading.latest(from: [try entry(sgv: 101, at: t0)], isLLU: true))
        XCTAssertNil(r.deltaMmol)
    }

    func testLatestTrendArrowUsesLibreScaleForLLU() throws {
        let r = try XCTUnwrap(SiriLiveReading.latest(from: [try entry(sgv: 101, at: t0, trend: 3)], isLLU: true))
        XCTAssertEqual(r.trendArrow, "\u{2192}")
    }

    func testLatestEmptyOrUnusableIsNil() throws {
        XCTAssertNil(SiriLiveReading.latest(from: [], isLLU: true))
        XCTAssertNil(SiriLiveReading.latest(from: [try entry(sgv: 250, at: t0, type: "mbg")], isLLU: true))
    }

    // MARK: reading(from:)

    func testReadingFromSnapshotWithoutValueIsNil() {
        XCTAssertNil(SiriLiveReading.reading(from: snapshot(value: nil)))
        XCTAssertNil(SiriLiveReading.reading(from: .empty))
    }

    func testReadingFromMmolSnapshot() throws {
        let r = try XCTUnwrap(SiriLiveReading.reading(from: snapshot(value: 5.6, delta: 0.3, dataStale: true)))
        XCTAssertEqual(r.mmol, 5.6, accuracy: 0.001)
        XCTAssertEqual(r.time, t0)
        XCTAssertEqual(try XCTUnwrap(r.deltaMmol), 0.3, accuracy: 0.001)
        XCTAssertEqual(r.trendArrow, "\u{2192}")
        XCTAssertTrue(r.flaggedStale)
    }

    func testReadingFromMgdlSnapshotConvertsToMmol() throws {
        let r = try XCTUnwrap(SiriLiveReading.reading(from: snapshot(value: 101, unit: "mg/dL")))
        XCTAssertEqual(r.mmol, 101 / 18.018, accuracy: 0.01)
        XCTAssertFalse(r.flaggedStale)
    }

    // MARK: merged(_:into:)

    func testMergedKeepsWidgetDataAndUpdatesReading() {
        let newTime = t0.addingTimeInterval(300)
        let r = SiriGlucoseReading(mmol: 7.2, time: newTime, deltaMmol: 0.4, trendArrow: "\u{2197}", flaggedStale: false)
        let m = SiriLiveReading.merged(r, into: snapshot(value: 5.0, delta: 0.2, dataStale: true))
        XCTAssertEqual(m.glucoseValue ?? 0, 7.2, accuracy: 0.001)
        XCTAssertEqual(m.glucoseUnit, "mmol/L")
        XCTAssertEqual(m.savedAt, newTime)
        XCTAssertEqual(m.deltaValue ?? 0, 0.4, accuracy: 0.001)
        XCTAssertEqual(m.trendArrow, "\u{2197}")
        XCTAssertEqual(m.dataStale, false)
        XCTAssertEqual(m.cobGrams, 12)
        XCTAssertEqual(m.iobUnits, 1.5)
        XCTAssertEqual(m.twoHourPredictionMmol, 6.2)
        XCTAssertEqual(m.chartPoints.count, 1)
    }

    func testMergedWritesInSnapshotUnit() {
        let r = SiriGlucoseReading(mmol: 7.2, time: t0, deltaMmol: 0.4, trendArrow: nil, flaggedStale: false)
        let m = SiriLiveReading.merged(r, into: snapshot(value: 90, unit: "mg/dL"))
        XCTAssertEqual(m.glucoseUnit, "mg/dL")
        XCTAssertEqual(m.glucoseValue ?? 0, 7.2 * 18.018, accuracy: 0.01)
        XCTAssertEqual(m.deltaValue ?? 0, 0.4 * 18.018, accuracy: 0.01)
    }

    func testMergedWithoutDeltaClearsDelta() {
        let r = SiriGlucoseReading(mmol: 7.2, time: t0, deltaMmol: nil, trendArrow: nil, flaggedStale: false)
        XCTAssertNil(SiriLiveReading.merged(r, into: snapshot(value: 5.0, delta: 0.2)).deltaValue)
    }
}
