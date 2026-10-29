import XCTest
@testable import GlucoseMonitor

/// Pure layout for glycemic event markers - no UI.
final class GlycemicEventMarkerLayoutTests: XCTestCase {

    private let t0 = Date(timeIntervalSince1970: 1_790_000_000)

    private func event(_ id: String, onset: TimeInterval, end: TimeInterval, phase: String = "FINAL",
                       state: String = "OPEN", parent: String? = nil, suppressed: Bool = false,
                       label: String = "Unaccounted carbs", category: String = "UNLOGGED_FOOD") -> BackendAPI.GlycemicEvent {
        BackendAPI.GlycemicEvent(id: id, category: category, detectorCategory: nil, userLabel: nil,
                                 displayLabel: label, direction: "RISE", phase: phase, state: state,
                                 onsetAt: t0.addingTimeInterval(onset), windowStart: t0.addingTimeInterval(onset),
                                 windowEnd: t0.addingTimeInterval(end), resolvesAt: nil, confidence: 0.6,
                                 suppressed: suppressed, linkedEventId: parent, meanResidualMmol: 3,
                                 promptOptions: [])
    }

    func testNearbyPillsMergeIntoACount() {
        let pills = GlycemicEventMarkerLayout.pills([
            (event: event("a", onset: 0, end: 600), x: 100),
            (event: event("b", onset: 60, end: 900), x: 120),
            (event: event("c", onset: 3600, end: 4200), x: 300),
        ])
        XCTAssertEqual(pills.count, 2)
        XCTAssertEqual(pills[0].label, "2 events")
        XCTAssertEqual(pills[0].eventIds, ["a", "b"])
        XCTAssertEqual(pills[1].label, "Unaccounted carbs")
    }

    func testProvisionalPillIsDashed() {
        let pills = GlycemicEventMarkerLayout.pills([(event: event("p", onset: 0, end: 600, phase: "PROVISIONAL",
                                                                  label: "Resistance?"), x: 50)])
        XCTAssertTrue(pills[0].dashed)
        XCTAssertEqual(pills[0].label, "Resistance?")
    }

    func testChildrenAndSuppressedGetNoPill() {
        let pills = GlycemicEventMarkerLayout.pills([
            (event: event("child", onset: 0, end: 600, parent: "p"), x: 50),
            (event: event("quiet", onset: 0, end: 600, suppressed: true), x: 200),
        ])
        XCTAssertTrue(pills.isEmpty)
    }

    func testSpanIsClippedToTheDomain() {
        let domain = t0.addingTimeInterval(0)...t0.addingTimeInterval(3600)
        let straddling = event("s", onset: -1800, end: 7200)   // starts before and ends after the chart
        let span = GlycemicEventMarkerLayout.clampedSpan(straddling, domain: domain)
        XCTAssertEqual(span?.lowerBound, domain.lowerBound)
        XCTAssertEqual(span?.upperBound, domain.upperBound)
    }

    func testEventsOutsideTheDomainOrDismissedAreHidden() {
        let domain = t0...t0.addingTimeInterval(3600)
        let outside = event("o", onset: 7200, end: 9000, category: "STRESS")
        let dismissed = event("d", onset: 600, end: 1200, state: "DISMISSED", category: "STRESS")
        let inside = event("i", onset: 600, end: 1200, category: "STRESS")
        XCTAssertNil(GlycemicEventMarkerLayout.clampedSpan(outside, domain: domain))
        XCTAssertEqual(GlycemicEventMarkerLayout.visible([outside, dismissed, inside], in: domain).map(\.id), ["i"])
    }

    func testUnloggedEventsStayOffTheChart() {
        let domain = t0...t0.addingTimeInterval(3600)
        let food = event("f", onset: 600, end: 1200, category: "UNLOGGED_FOOD")
        let insulin = event("u", onset: 600, end: 1200, category: "UNLOGGED_INSULIN")
        let stress = event("s", onset: 600, end: 1200, category: "STRESS")
        XCTAssertEqual(GlycemicEventMarkerLayout.visible([food, insulin, stress], in: domain).map(\.id), ["s"])
    }
}
