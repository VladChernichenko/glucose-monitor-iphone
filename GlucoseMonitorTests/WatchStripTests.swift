import XCTest
@testable import GlucoseMonitor

/// Pins the `watch` JSON, its two lines of text, and when AppState shows it.
@MainActor
final class WatchStripTests: XCTestCase {

    private func response(watch: String?) throws -> BackendAPI.GlucoseCalculationsResponse {
        let w = watch.map { ",\"watch\":\($0)" } ?? ""
        let json = """
        {"activeCarbsOnBoard":0,"activeInsulinOnBoard":1.2,"twoHourPrediction":5.0,"predictionTrend":"falling",
         "confidence":0.8\(w)}
        """.data(using: .utf8)!
        return try JSONDecoder().decode(BackendAPI.GlucoseCalculationsResponse.self, from: json)
    }

    private func strip(state: String = "CALM", reason: String, suggestion: String = "null",
                       low: String = "null", landing: String = "null",
                       iob: String = "1.2", cob: String = "30", activity: String = "LEARNED") throws -> BackendAPI.WatchStrip {
        let r = try response(watch: """
        {"state":"\(state)","reason":"\(reason)","suggestion":\(suggestion),"low":\(low),"landing":\(landing),
         "iob":\(iob),"cob":\(cob),"nextCheckAt":"2026-10-31T19:15:00","activityEstimate":"\(activity)"}
        """)
        return try XCTUnwrap(r.watch)
    }

    private let low = #"{"at":"2026-10-31T19:40:00","mmol":3.6}"#
    private let landing = #"{"at":"2026-10-31T23:00:00","mmol":10.4}"#

    private func at(_ s: String) -> String {
        ChatFormatting.clock(BackendAPI.parseBackendDate(s)!)
    }

    // MARK: decoding

    func testDecodesFullWatch() throws {
        let s = try strip(state: "URGENT_LOW", reason: "FORECAST_LOW",
                          suggestion: #"{"kind":"CARBS","grams":15,"units":null,"refusalCode":null,"targetMmol":null,"isf":null,"minWithCarbs":4.4}"#,
                          low: low, landing: landing, activity: "DEFAULT")
        XCTAssertEqual(s.state, .urgentLow)
        XCTAssertEqual(s.reason, .forecastLow)
        XCTAssertEqual(s.suggestion?.kind, .carbs)
        XCTAssertEqual(s.suggestion?.grams, 15)
        XCTAssertEqual(s.suggestion?.minWithCarbs ?? 0, 4.4, accuracy: 0.001)
        XCTAssertEqual(s.low?.mmol ?? 0, 3.6, accuracy: 0.001)
        XCTAssertEqual(s.landing?.mmol ?? 0, 10.4, accuracy: 0.001)
        XCTAssertEqual(s.iob ?? 0, 1.2, accuracy: 0.001)
        XCTAssertEqual(s.cob ?? 0, 30, accuracy: 0.001)
        XCTAssertEqual(s.activityEstimate, .default)
        XCTAssertEqual(s.nextCheckAt, BackendAPI.parseBackendDate("2026-10-31T19:15:00"))
        XCTAssertTrue(s.isKnown)
    }

    func testDecodesMissingWatchAsNil() throws {
        XCTAssertNil(try response(watch: nil).watch)
        XCTAssertNil(try response(watch: "null").watch)
    }

    func testUnknownStateHidden() throws {
        let s = try strip(state: "SOMETHING_NEW", reason: "WATCHING")
        XCTAssertEqual(s.state, .unknown)
        XCTAssertFalse(s.isKnown)
        let app = AppState()
        app.calculations = try response(watch: """
        {"state":"SOMETHING_NEW","reason":"WATCHING","nextCheckAt":"2026-10-31T19:15:00"}
        """)
        XCTAssertNotNil(app.calculations?.watch)
        XCTAssertNil(app.visibleWatchStrip)
    }

    // MARK: text

    private let carbs = #"{"kind":"CARBS","grams":15,"units":null,"refusalCode":null,"targetMmol":null,"isf":null,"minWithCarbs":4.4}"#

    func testForecastLowText_mmol() throws {
        let s = try strip(state: "URGENT_LOW", reason: "FORECAST_LOW", suggestion: carbs, low: low)
        XCTAssertEqual(WatchStripText.headline(s, unit: "mmol/L"), "Low likely ~\(at("2026-10-31T19:40:00")) (3.6 mmol/L)")
        XCTAssertEqual(WatchStripText.detail(s, unit: "mmol/L"),
                       "Take 15 g now \u{2192} min 4.4 mmol/L \u{00B7} recheck \(at("2026-10-31T19:15:00"))")
    }

    func testForecastLowText_mgdl() throws {
        let s = try strip(state: "URGENT_LOW", reason: "FORECAST_LOW", suggestion: carbs, low: low)
        XCTAssertEqual(WatchStripText.headline(s, unit: "mg/dL"), "Low likely ~\(at("2026-10-31T19:40:00")) (65 mg/dL)")
        XCTAssertTrue(WatchStripText.detail(s, unit: "mg/dL").contains("min 79 mg/dL"))
    }

    func testCorrectionText_showsTargetAndIsf() throws {
        let s = try strip(state: "URGENT_HIGH", reason: "HIGH_FORECAST",
                          suggestion: #"{"kind":"INSULIN","grams":null,"units":1.55,"refusalCode":null,"targetMmol":5.5,"isf":2.2,"minWithCarbs":null}"#,
                          landing: landing)
        XCTAssertEqual(WatchStripText.headline(s, unit: "mmol/L"), "High ahead: 10.4 mmol/L at \(at("2026-10-31T23:00:00"))")
        XCTAssertEqual(WatchStripText.detail(s, unit: "mmol/L"),
                       "Correction 1.6 U (target 5.5, ISF 2.2) \u{00B7} recheck \(at("2026-10-31T19:15:00"))")
    }

    func testRefusalText_mapsCodes() throws {
        func detail(_ code: String, unit: String = "mmol/L") throws -> String {
            let s = try strip(state: "URGENT_HIGH", reason: "HIGH_FORECAST",
                              suggestion: #"{"kind":"REFUSED","refusalCode":"\#(code)"}"#, landing: landing)
            return WatchStripText.detail(s, unit: unit)
        }
        let tail = " \u{00B7} recheck \(at("2026-10-31T19:15:00"))"
        XCTAssertEqual(try detail("GLUCOSE_BELOW_SAFE_THRESHOLD"), "No dose: glucose under 3.9 mmol/L" + tail)
        XCTAssertEqual(try detail("GLUCOSE_BELOW_SAFE_THRESHOLD", unit: "mg/dL"), "No dose: glucose under 70 mg/dL" + tail)
        XCTAssertEqual(try detail("DOSE_EXCEEDS_MAX_BOLUS"), "No dose: over your safety limit" + tail)
        XCTAssertEqual(try detail("SETTINGS_INVALID"), "No dose: check your ISF settings" + tail)
        XCTAssertEqual(try detail("INSULIN_PARAMS_INCONSISTENT"), "No dose: check your ISF settings" + tail)
        XCTAssertEqual(try detail("WHATEVER"), "No dose: can't calculate" + tail)
    }

    func testRoughActivitySuffix_onlyWhenDefault() throws {
        let rough = " \u{00B7} activity estimate still rough"
        let watching = try strip(reason: "WATCHING", landing: landing, activity: "DEFAULT")
        XCTAssertEqual(WatchStripText.headline(watching, unit: "mmol/L"), "Watching \u{00B7} 1.2 U, 30 g active")
        XCTAssertEqual(WatchStripText.detail(watching, unit: "mmol/L"),
                       "Lands 10.4 mmol/L by \(at("2026-10-31T23:00:00"))" + rough)
        let dip = try strip(reason: "DIP_AHEAD", low: low, activity: "DEFAULT")
        XCTAssertTrue(WatchStripText.detail(dip, unit: "mmol/L").hasSuffix("have 10\u{2013}15 g ready" + rough))
        let learned = try strip(reason: "DIP_AHEAD", low: low, activity: "LEARNED")
        XCTAssertFalse(WatchStripText.detail(learned, unit: "mmol/L").contains("rough"))
        let high = try strip(state: "URGENT_HIGH", reason: "SMALL_RISE", landing: landing, activity: "DEFAULT")
        XCTAssertFalse(WatchStripText.detail(high, unit: "mmol/L").contains("rough"))
    }

    // MARK: visibility

    private func app(watch: Bool = true) throws -> AppState {
        let a = AppState()
        a.calculations = try response(watch: watch ? """
        {"state":"CALM","reason":"WATCHING","nextCheckAt":"2026-10-31T19:15:00","activityEstimate":"LEARNED"}
        """ : nil)
        return a
    }

    func testVisibleWhenFreshAndKnown() throws {
        XCTAssertNotNil(try app().visibleWatchStrip)
        XCTAssertNil(try app(watch: false).visibleWatchStrip)
    }

    func testHiddenWhenCached() throws {
        let a = try app()
        a.calculationsFromCache = true
        XCTAssertNil(a.visibleWatchStrip)
    }

    func testHiddenWhenCalculationsStale() throws {
        let a = try app()
        a.calculationsStale = true
        XCTAssertNil(a.visibleWatchStrip)
    }

    func testHiddenWhenLibreStale() throws {
        let a = try app()
        a.libreDataStale = true
        XCTAssertNil(a.visibleWatchStrip)
    }

    // MARK: - Target and rescue-carb settings

    private func cobJSON(extra: String = "") -> Data {
        """
        {"carbRatio":2.0,"isf":2.5,"carbHalfLife":60,"maxCOBDuration":240\(extra)}
        """.data(using: .utf8)!
    }

    func cobSettings_encodesTargetAndRescue() throws {
        var s = try JSONDecoder().decode(BackendAPI.COBSettings.self, from: cobJSON())
        s.targetGlucoseMmol = 5.6
        s.rescueCarbsG = 20
        let obj = try JSONSerialization.jsonObject(with: JSONEncoder().encode(s)) as? [String: Any]
        XCTAssertEqual(obj?["targetGlucoseMmol"] as? Double, 5.6)
        XCTAssertEqual(obj?["rescueCarbsG"] as? Int, 20)
    }

    func cobSettings_decodesWithoutNewFields() throws {
        let s = try JSONDecoder().decode(BackendAPI.COBSettings.self, from: cobJSON())
        XCTAssertNil(s.targetGlucoseMmol)
        XCTAssertNil(s.rescueCarbsG)
    }

    func target_mgdl100_is555() throws {
        let mmol = try XCTUnwrap(TargetGlucoseInput.mmol(fromDisplay: 100, unit: "mg/dL"))
        XCTAssertEqual(mmol, 5.55, accuracy: 0.01)
    }

    func target_outOfRange_nil() {
        XCTAssertNil(TargetGlucoseInput.mmol(fromDisplay: 78, unit: "mg/dL"))
        XCTAssertNil(TargetGlucoseInput.mmol(fromDisplay: 10.1, unit: "mmol/L"))
    }

    func target_rangeEdges_acceptedAndWithinBackendBounds() throws {
        let low = try XCTUnwrap(TargetGlucoseInput.mmol(fromDisplay: 79, unit: "mg/dL"))
        XCTAssertGreaterThanOrEqual(low, 4.4)
        let high = try XCTUnwrap(TargetGlucoseInput.mmol(fromDisplay: 180, unit: "mg/dL"))
        XCTAssertLessThanOrEqual(high, 10.0)
        XCTAssertNotNil(TargetGlucoseInput.mmol(fromDisplay: 4.4, unit: "mmol/L"))
        XCTAssertNotNil(TargetGlucoseInput.mmol(fromDisplay: 10.0, unit: "mmol/L"))
        XCTAssertNil(TargetGlucoseInput.mmol(fromDisplay: 4.3, unit: "mmol/L"))
    }

    func target_displayRoundTrip() {
        XCTAssertEqual(TargetGlucoseInput.display(mmol: 5.6, unit: "mmol/L"), 5.6, accuracy: 0.001)
        XCTAssertEqual(TargetGlucoseInput.display(mmol: 5.55, unit: "mg/dL"), 100, accuracy: 0.001)
    }
}
