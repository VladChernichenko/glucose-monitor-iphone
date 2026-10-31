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

    func testButtonTitlesReportWhatHappenedAndNeverReadAsDosingInstructions() {
        XCTAssertEqual(GlycemicCategory.buttonTitle("UNDER_ESTIMATED_INSULIN"), "Took more than logged")
        XCTAssertEqual(GlycemicCategory.buttonTitle("UNDER_ESTIMATED_FOOD"), "Ate more than logged")
        XCTAssertEqual(GlycemicCategory.buttonTitle("UNLOGGED_INSULIN"), "Took unlogged insulin")
        let all = ["UNLOGGED_FOOD", "UNDER_ESTIMATED_FOOD", "STRESS", "ABSORPTION_DELAY", "LIPODYSTROPHY",
                   "DAWN_PHENOMENON", "ANAEROBIC_ACTIVITY", "UNLOGGED_INSULIN", "UNDER_ESTIMATED_INSULIN", "AEROBIC_ACTIVITY"]
        for raw in all {
            let title = GlycemicCategory.buttonTitle(raw).lowercased()
            XCTAssertFalse(title.contains("dose"), raw)
            XCTAssertFalse(title.hasPrefix("take "), raw)
            XCTAssertFalse(title.hasPrefix("more insulin"), raw)
            XCTAssertFalse(title.hasPrefix("ate more") && !title.contains("than logged"), raw)
        }
    }
}
