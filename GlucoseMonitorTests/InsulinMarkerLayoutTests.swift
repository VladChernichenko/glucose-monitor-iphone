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
