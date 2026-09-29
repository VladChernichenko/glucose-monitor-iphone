import XCTest
@testable import GlucoseMonitor

/// Unit tests for `InsulinMarkerLayout` - pure chart-marker logic, no networking, no UI.
/// Pyramid layer: Unit (base).
///
/// Regression context: the chart summed every insulin note within the grouping threshold, so an
/// 18 u long-acting dose logged next to a 2 u correction was drawn as a single "20" bar.
final class InsulinMarkerLayoutTests: XCTestCase {

    private typealias Kind = InsulinMarkerLayout.Kind

    func testLongActingAndRapidAtSameTime_areSeparateMarkersSideBySide() {
        let markers = InsulinMarkerLayout.markers([
            (isLongActing: true, units: 18, x: 100),
            (isLongActing: false, units: 2, x: 104),
        ])

        XCTAssertEqual(markers.count, 2)
        let rapid = markers.first { $0.kind == .rapid }
        let long = markers.first { $0.kind == .longActing }
        XCTAssertEqual(rapid?.units, 2)
        XCTAssertEqual(long?.units, 18)
        // Side by side around the pair's midpoint, rapid on the left.
        XCTAssertEqual(rapid!.x, 102 - InsulinMarkerLayout.sideBySideOffset, accuracy: 0.001)
        XCTAssertEqual(long!.x, 102 + InsulinMarkerLayout.sideBySideOffset, accuracy: 0.001)
    }

    func testNearbyDosesOfTheSameKind_areStillSummed() {
        let markers = InsulinMarkerLayout.markers([
            (isLongActing: false, units: 2, x: 100),
            (isLongActing: false, units: 3, x: 110),
        ])

        XCTAssertEqual(markers, [InsulinMarkerLayout.Marker(kind: .rapid, units: 5, x: 105)])
    }

    func testDistantDosesOfDifferentKinds_keepTheirPositions() {
        let markers = InsulinMarkerLayout.markers([
            (isLongActing: true, units: 18, x: 100),
            (isLongActing: false, units: 2, x: 300),
        ])

        XCTAssertEqual(markers.first { $0.kind == .longActing }?.x, 100)
        XCTAssertEqual(markers.first { $0.kind == .rapid }?.x, 300)
    }

    func testZeroUnitNotes_produceNoMarker() {
        XCTAssertTrue(InsulinMarkerLayout.markers([(isLongActing: false, units: 0, x: 100)]).isEmpty)
    }
}

/// Editing a long-acting note goes through LongActingInsulinSheet, which must change only the
/// dose and time - never the stored insulin name or the long_acting type.
final class LongActingEditBodyTests: XCTestCase {

    func testEditBody_carriesDoseAndTimeOnly() {
        let at = Date(timeIntervalSince1970: 1_790_712_600)
        let body = LongActingInsulinSheet.editBody(dose: 18, at: at)

        XCTAssertEqual(body.insulin, 18)
        XCTAssertEqual(body.timestamp, BackendAPI.formatNoteTimestampForRequest(at))
        XCTAssertNil(body.meal, "the original insulin name must be preserved")
        XCTAssertNil(body.type, "the note must stay long_acting")
        XCTAssertNil(body.carbs)
    }
}
