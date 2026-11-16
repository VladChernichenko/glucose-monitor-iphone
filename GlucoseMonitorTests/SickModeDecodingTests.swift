import XCTest
@testable import GlucoseMonitor

/// Pins the sick-mode status JSON the backend sends, and that a bad `sickMode` never fails the dashboard.
final class SickModeDecodingTests: XCTestCase {

    private let status = """
    {"active":true,"severity":"MODERATE","since":"2026-11-15T07:30:00","dayNumber":2,"isfPercent":-30,
     "basalNeedPercent":15,"confirmationDue":true,
     "stepUp":{"noteId":"7B1E5A52-3C11-4E4B-8F0A-0A8C5C1D2E3F","toSeverity":"SEVERE","showHelpLine":false}}
    """

    private func calculations(sickMode: String?) -> Data {
        let extra = sickMode.map { ",\"sickMode\":\($0)" } ?? ""
        return Data("""
        {"backendMode":true,"data":{"activeCarbsOnBoard":0,"activeInsulinOnBoard":0,"twoHourPrediction":6.0,
         "fourHourPrediction":6.0,"predictionTrend":"stable","confidence":0.5\(extra)}}
        """.utf8)
    }

    func testDecodesActiveStatusWithStepUp() throws {
        let s = try GlucoseMonitorAPI.jsonDecoder().decode(SickModeStatus.self, from: Data(status.utf8))
        XCTAssertTrue(s.active)
        XCTAssertEqual(s.severity, .moderate)
        XCTAssertEqual(s.dayNumber, 2)
        XCTAssertEqual(s.isfPercent, -30)
        XCTAssertEqual(s.basalNeedPercent, 15)
        XCTAssertTrue(s.confirmationDue)
        XCTAssertEqual(s.stepUp?.toSeverity, .severe)
        XCTAssertEqual(s.stepUp?.noteId, UUID(uuidString: "7B1E5A52-3C11-4E4B-8F0A-0A8C5C1D2E3F"))
        XCTAssertEqual(s.stepUp?.showHelpLine, false)
        let c = Calendar.current.dateComponents([.year, .month, .day, .hour, .minute], from: try XCTUnwrap(s.since))
        XCTAssertEqual([c.year, c.month, c.day, c.hour, c.minute], [2026, 11, 15, 7, 30], "wall-clock time, no zone shift")
    }

    func testDecodesInactiveStatusWithNulls() throws {
        let json = #"{"active":false,"severity":null,"since":null,"dayNumber":null,"isfPercent":null,"basalNeedPercent":null,"confirmationDue":false,"stepUp":null}"#
        let s = try GlucoseMonitorAPI.jsonDecoder().decode(SickModeStatus.self, from: Data(json.utf8))
        XCTAssertFalse(s.active)
        XCTAssertNil(s.severity)
        XCTAssertNil(s.since)
        XCTAssertNil(s.stepUp)
    }

    func testUnknownSeverityDropsTheStatusNotTheDashboard() throws {
        let bad = status.replacingOccurrences(of: "\"MODERATE\"", with: "\"EXTREME\"")
        let r = try XCTUnwrap(BackendAPI.decodeGlucoseCalculationsResponse(from: calculations(sickMode: bad)))
        XCTAssertNil(r.sickMode)
        XCTAssertEqual(r.twoHourPrediction, 6.0)
    }

    func testDashboardCarriesSickModeWhenValid() throws {
        let r = try XCTUnwrap(BackendAPI.decodeGlucoseCalculationsResponse(from: calculations(sickMode: status)))
        XCTAssertEqual(r.sickMode?.severity, .moderate)
    }

    func testAbsentSickModeIsNil() throws {
        let r = try XCTUnwrap(BackendAPI.decodeGlucoseCalculationsResponse(from: calculations(sickMode: nil)))
        XCTAssertNil(r.sickMode)
    }

    func testSevereUnresponsiveIsNeverSelectable() {
        XCTAssertEqual(SickSeverity.allCases.filter(\.selectable), [.mild, .moderate, .severe])
    }
}
