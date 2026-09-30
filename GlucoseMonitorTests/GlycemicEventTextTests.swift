import XCTest
@testable import GlucoseMonitor

final class GlycemicEventTextTests: XCTestCase {

    private func event(direction: String, phase: String, mean: Double, minutes: Double) -> BackendAPI.GlycemicEvent {
        let onset = Date(timeIntervalSince1970: 1_790_000_000)
        return BackendAPI.GlycemicEvent(id: "e", category: "STRESS", detectorCategory: nil, userLabel: nil,
                                        displayLabel: "Resistance?", direction: direction, phase: phase, state: "OPEN",
                                        onsetAt: onset, windowStart: onset, windowEnd: onset.addingTimeInterval(minutes * 60),
                                        resolvesAt: nil, confidence: 0.5, suppressed: false, linkedEventId: nil,
                                        meanResidualMmol: mean, promptOptions: [])
    }

    func testQuestions() {
        XCTAssertEqual(GlycemicEventCopy.question(for: event(direction: "RISE", phase: "PROVISIONAL", mean: 3, minutes: 60)),
                       "Your glucose held up although insulin was active. What's going on?")
        XCTAssertEqual(GlycemicEventCopy.question(for: event(direction: "FALL", phase: "PROVISIONAL", mean: -3, minutes: 60)),
                       "Your glucose dropped more than expected. What happened?")
        XCTAssertEqual(GlycemicEventCopy.question(for: event(direction: "RISE", phase: "FINAL", mean: 3, minutes: 60)),
                       "Does this look right?")
    }

    func testSummaryUsesTheDisplayUnit() {
        let e = event(direction: "RISE", phase: "FINAL", mean: 3.0, minutes: 70)
        XCTAssertEqual(GlycemicEventCopy.summary(for: e, displayUnit: "mmol/L"),
                       "3.0 mmol/L above the forecast for 70 min")
        XCTAssertEqual(GlycemicEventCopy.summary(for: e, displayUnit: "mg/dL"),
                       "54 mg/dL above the forecast for 70 min")
    }

    func testAmountParsingAcceptsCommaDecimals() {
        XCTAssertEqual(GlycemicAmount.parse("2,5"), 2.5)
        XCTAssertEqual(GlycemicAmount.parse(" 20 "), 20)
        XCTAssertNil(GlycemicAmount.parse(""))
        XCTAssertNil(GlycemicAmount.parse("-3"))
        XCTAssertNil(GlycemicAmount.parse("abc"))
    }

    func testPeakHour() {
        var h = Array(repeating: 0, count: 24)
        XCTAssertNil(GlycemicInsightsText.peakHour(h))
        h[10] = 3; h[16] = 1
        XCTAssertEqual(GlycemicInsightsText.peakHour(h), 10)
    }

    func testNoEffectLineOnlyWhenThereAreCases() {
        XCTAssertNil(GlycemicInsightsText.noEffectLine(0))
        XCTAssertEqual(GlycemicInsightsText.noEffectLine(4),
                       "4 insulin doses in the last 14 days showed no measurable effect. Consider checking your injection sites.")
    }

    func testByDayGroupsNewestFirstAndSkipsChildren() {
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = TimeZone(identifier: "UTC")!
        let day1 = Date(timeIntervalSince1970: 1_790_000_000)          // some day, 10:13 UTC
        let day2 = day1.addingTimeInterval(86_400)
        func ev(_ id: String, _ at: Date, parent: String? = nil) -> BackendAPI.GlycemicEvent {
            BackendAPI.GlycemicEvent(id: id, category: "STRESS", detectorCategory: nil, userLabel: nil,
                                     displayLabel: "x", direction: "RISE", phase: "FINAL", state: "OPEN",
                                     onsetAt: at, windowStart: at, windowEnd: at.addingTimeInterval(600),
                                     resolvesAt: nil, confidence: 0.6, suppressed: false, linkedEventId: parent,
                                     meanResidualMmol: 2, promptOptions: [])
        }
        let groups = GlycemicInsightsText.byDay([ev("a", day1), ev("b", day2), ev("c", day2, parent: "b")], calendar: cal)
        XCTAssertEqual(groups.map { $0.events.map(\.id) }, [["b"], ["a"]])
    }
}
