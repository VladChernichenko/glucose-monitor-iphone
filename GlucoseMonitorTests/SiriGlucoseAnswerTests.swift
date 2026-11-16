import XCTest
@testable import GlucoseMonitor

/// Pins what Siri says and when a cached reading is trusted without a network call.
final class SiriGlucoseAnswerTests: XCTestCase {

    private let now = Date(timeIntervalSince1970: 1_800_000_000)

    private func reading(mmol: Double = 5.6, ageMinutes: Double, flaggedStale: Bool = false) -> SiriGlucoseReading {
        SiriGlucoseReading(
            mmol: mmol,
            time: now.addingTimeInterval(-ageMinutes * 60),
            deltaMmol: nil,
            trendArrow: nil,
            flaggedStale: flaggedStale
        )
    }

    func testCurrentMmol() {
        XCTAssertEqual(
            SiriGlucoseAnswer.spokenText(reading(ageMinutes: 1), displayUnit: "mmol/L", now: now),
            "Your blood sugar is 5.6 mmol/L."
        )
    }

    func testCurrentMgdl() {
        XCTAssertEqual(
            SiriGlucoseAnswer.spokenText(reading(ageMinutes: 1), displayUnit: "mg/dL", now: now),
            "Your blood sugar is 101 mg/dL."
        )
    }

    func testStillCurrentAt15Minutes() {
        XCTAssertEqual(
            SiriGlucoseAnswer.spokenText(reading(ageMinutes: 15), displayUnit: "mmol/L", now: now),
            "Your blood sugar is 5.6 mmol/L."
        )
    }

    func testOldReadingSaysAge() {
        XCTAssertEqual(
            SiriGlucoseAnswer.spokenText(reading(ageMinutes: 16), displayUnit: "mmol/L", now: now),
            "Your last reading was 16 minutes ago: 5.6 mmol/L."
        )
    }

    func testFlaggedStaleSaysAgeEvenWhenRecent() {
        XCTAssertEqual(
            SiriGlucoseAnswer.spokenText(reading(ageMinutes: 2, flaggedStale: true), displayUnit: "mmol/L", now: now),
            "Your last reading was 2 minutes ago: 5.6 mmol/L."
        )
    }

    func testFlaggedStaleBrandNewReadingIsOneMinuteSingular() {
        XCTAssertEqual(
            SiriGlucoseAnswer.spokenText(reading(ageMinutes: 0, flaggedStale: true), displayUnit: "mmol/L", now: now),
            "Your last reading was 1 minute ago: 5.6 mmol/L."
        )
    }

    func testHoursPhrasing() {
        XCTAssertEqual(
            SiriGlucoseAnswer.spokenText(reading(ageMinutes: 60), displayUnit: "mmol/L", now: now),
            "Your last reading was 1 hour ago: 5.6 mmol/L."
        )
        XCTAssertEqual(
            SiriGlucoseAnswer.spokenText(reading(ageMinutes: 125), displayUnit: "mmol/L", now: now),
            "Your last reading was 2 hours ago: 5.6 mmol/L."
        )
    }

    func testNilIsUnavailable() {
        XCTAssertEqual(
            SiriGlucoseAnswer.spokenText(nil, displayUnit: "mmol/L", now: now),
            SiriGlucoseAnswer.unavailableText
        )
        XCTAssertEqual(SiriGlucoseAnswer.unavailableText, "I can't get your blood sugar right now.")
    }

    /// Clock skew between phone and backend must never produce "-1 minutes ago".
    func testFutureTimestampIsCurrent() {
        XCTAssertEqual(
            SiriGlucoseAnswer.spokenText(reading(ageMinutes: -1.5), displayUnit: "mmol/L", now: now),
            "Your blood sugar is 5.6 mmol/L."
        )
    }

    func testCacheFreshBoundary() {
        XCTAssertTrue(SiriGlucoseAnswer.isCacheFresh(reading(ageMinutes: 5), now: now))
        XCTAssertFalse(SiriGlucoseAnswer.isCacheFresh(reading(ageMinutes: 5.02), now: now))
        XCTAssertFalse(SiriGlucoseAnswer.isCacheFresh(reading(ageMinutes: 1, flaggedStale: true), now: now))
    }
}
