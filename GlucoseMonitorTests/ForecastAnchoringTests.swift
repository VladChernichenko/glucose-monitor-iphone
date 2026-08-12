import XCTest
@testable import GlucoseMonitor

/// Unit tests for `ForecastAnchoring` - pure chart-series logic, no networking, no UI.
/// Pyramid layer: Unit (base).
///
/// Regression context: the dashed forecast used to be anchored at `Date()` while the backend
/// path is anchored at the moment the calculation ran. With a response one emit interval old,
/// the whole first 5-minute step of the model collapsed into the seconds between "now" and the
/// first emitted point, drawing a vertical step at the solid/dashed join.
final class ForecastAnchoringTests: XCTestCase {

    private let step: TimeInterval = 5 * 60

    private func path(from calcTime: Date,
                      step: TimeInterval,
                      values: [Double]) -> [PredictionChartPoint] {
        values.enumerated().map { i, v in
            PredictionChartPoint(time: calcTime.addingTimeInterval(step * Double(i + 1)), mmol: v)
        }
    }

    // MARK: - origin(of:)

    func testOrigin_isFirstPointMinusOneEmitInterval() {
        let calcTime = Date()
        let p = path(from: calcTime, step: step, values: [7.9, 8.1, 8.3])

        let origin = try? XCTUnwrap(ForecastAnchoring.origin(of: p))

        XCTAssertEqual(origin?.timeIntervalSince1970 ?? 0,
                       calcTime.timeIntervalSince1970, accuracy: 0.001)
    }

    func testOrigin_usesMeasuredSpacing_notTheDefault() {
        // Sparse tail of the path emits every 10 min, not 5.
        let calcTime = Date()
        let p = path(from: calcTime, step: 600, values: [7.9, 8.1])

        let origin = ForecastAnchoring.origin(of: p)

        XCTAssertEqual(origin?.timeIntervalSince(p[0].time) ?? 0, -600, accuracy: 0.001)
    }

    func testOrigin_singlePointFallsBackToDefaultStep() {
        let only = [PredictionChartPoint(time: Date(), mmol: 7.9)]

        let origin = ForecastAnchoring.origin(of: only)

        XCTAssertEqual(origin?.timeIntervalSince(only[0].time) ?? 0,
                       -ForecastAnchoring.defaultStep, accuracy: 0.001)
    }

    func testOrigin_emptyPathHasNoOrigin() {
        XCTAssertNil(ForecastAnchoring.origin(of: []))
    }

    // MARK: - The regression: first segment keeps its true width

    func testFirstSegmentSpansAFullEmitInterval_evenWhenResponseIsNearlyAStepOld() {
        // Response is 4 min 13 s old (the state in the reported screenshot): the first emitted
        // point is only 47 s in the future. Anchoring at `Date()` compressed a 5-minute move
        // into those 47 s; anchoring at the path origin must not.
        let calcTime = Date().addingTimeInterval(-253)
        let p = path(from: calcTime, step: step, values: [8.08, 8.28, 8.40])

        let series = ForecastAnchoring.series(path: p, anchorMmol: 7.8,
                                              horizonEnd: Date().addingTimeInterval(4 * 3600))

        XCTAssertEqual(series.count, 4)
        XCTAssertEqual(series[1].time.timeIntervalSince(series[0].time), step, accuracy: 0.001)
    }

    func testAnchorGapIsIndependentOfResponseAge() {
        // Whatever the age, the anchor sits exactly one interval before the first point.
        for ageSeconds in [0.0, 60.0, 253.0, 299.0] {
            let calcTime = Date().addingTimeInterval(-ageSeconds)
            let p = path(from: calcTime, step: step, values: [8.0, 8.2])

            let series = ForecastAnchoring.series(path: p, anchorMmol: 7.8,
                                                  horizonEnd: Date().addingTimeInterval(4 * 3600))

            XCTAssertEqual(series[1].time.timeIntervalSince(series[0].time), step,
                           accuracy: 0.001, "age \(ageSeconds)s")
        }
    }

    // MARK: - series(path:anchorMmol:horizonEnd:)

    func testSeries_anchorCarriesCurrentGlucoseWithBandPinchedShut() {
        let p = path(from: Date(), step: step, values: [8.0, 8.2])

        let series = ForecastAnchoring.series(path: p, anchorMmol: 7.8,
                                              horizonEnd: Date().addingTimeInterval(4 * 3600))

        XCTAssertEqual(series[0].mmol, 7.8, accuracy: 0.0001)
        XCTAssertEqual(series[0].lower ?? .nan, 7.8, accuracy: 0.0001)
        XCTAssertEqual(series[0].upper ?? .nan, 7.8, accuracy: 0.0001)
    }

    func testSeries_dropsPointsBeyondTheHorizon() {
        let calcTime = Date()
        let p = path(from: calcTime, step: 3600, values: [8.0, 8.2, 8.4, 8.6])

        let series = ForecastAnchoring.series(path: p, anchorMmol: 7.8,
                                              horizonEnd: calcTime.addingTimeInterval(2 * 3600))

        // anchor + the two points at +1 h and +2 h.
        XCTAssertEqual(series.count, 3)
        XCTAssertEqual(series.last?.mmol ?? .nan, 8.2, accuracy: 0.0001)
    }

    func testSeries_emptyPathYieldsNoSeries() {
        let series = ForecastAnchoring.series(path: [], anchorMmol: 7.8,
                                              horizonEnd: Date().addingTimeInterval(4 * 3600))

        XCTAssertTrue(series.isEmpty)
    }

    func testSeries_keepsPastPointsSoAStaleForecastLooksStale() {
        // A 12-minute-old response: the +5 and +10 points are already behind us. They must be
        // kept - dropping them reintroduces the compression this anchoring exists to remove.
        let calcTime = Date().addingTimeInterval(-12 * 60)
        let p = path(from: calcTime, step: step, values: [8.0, 8.2, 8.4, 8.5])

        let series = ForecastAnchoring.series(path: p, anchorMmol: 7.8,
                                              horizonEnd: Date().addingTimeInterval(4 * 3600))

        XCTAssertEqual(series.count, 5)
        XCTAssertTrue(series[0].time < Date())
        XCTAssertEqual(series[1].time.timeIntervalSince(series[0].time), step, accuracy: 0.001)
    }
}
