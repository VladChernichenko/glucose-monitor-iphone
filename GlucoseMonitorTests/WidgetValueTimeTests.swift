import XCTest
@testable import GlucoseMonitor

/// The widget snapshot (and so Siri) must date a glucose value by when THAT value was measured,
/// not by the CGM sample time when the value actually came from a logged fingerstick.
@MainActor
final class WidgetValueTimeTests: XCTestCase {

    private let now = Date(timeIntervalSince1970: 1_800_000_000)

    private func ago(_ minutes: Double) -> Date { now.addingTimeInterval(-minutes * 60) }

    func testFreshCgmDatesTheValueByTheCgmSample() {
        let t = AppState.glucoseValueTime(cgmTimestamp: ago(10), newestHistoryTime: ago(10),
                                          manualTimestamp: ago(5), now: now)
        XCTAssertEqual(t, ago(10))
    }

    /// CGM is over 30 min old, so the value comes from the fingerstick note: date it by the note.
    func testStaleCgmWithFingerstickDatesTheValueByTheNote() {
        let t = AppState.glucoseValueTime(cgmTimestamp: ago(45), newestHistoryTime: ago(45),
                                          manualTimestamp: ago(120), now: now)
        XCTAssertEqual(t, ago(120))
    }

    /// No CGM in memory at all: must not be dated "now".
    func testNoCgmWithFingerstickDatesTheValueByTheNote() {
        let t = AppState.glucoseValueTime(cgmTimestamp: nil, newestHistoryTime: nil,
                                          manualTimestamp: ago(90), now: now)
        XCTAssertEqual(t, ago(90))
    }

    func testStaleCgmWithoutFingerstickKeepsTheCgmSample() {
        let t = AppState.glucoseValueTime(cgmTimestamp: ago(45), newestHistoryTime: ago(45),
                                          manualTimestamp: nil, now: now)
        XCTAssertEqual(t, ago(45))
    }

    func testNothingAtAllFallsBackToHistoryThenNow() {
        XCTAssertEqual(AppState.glucoseValueTime(cgmTimestamp: nil, newestHistoryTime: ago(7),
                                                 manualTimestamp: nil, now: now), ago(7))
        XCTAssertEqual(AppState.glucoseValueTime(cgmTimestamp: nil, newestHistoryTime: nil,
                                                 manualTimestamp: nil, now: now), now)
    }
}
