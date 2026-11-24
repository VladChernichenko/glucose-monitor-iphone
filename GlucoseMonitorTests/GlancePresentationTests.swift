import XCTest
@testable import GlucoseMonitor

/// What the Apple Watch screen and complication draw from a glance.
final class GlancePresentationTests: XCTestCase {

    private let now = Date(timeIntervalSince1970: 1_795_512_143)

    // MARK: helpers

    private func stripJSON(state: String, reason: String, kind: String? = nil, units: String = "null",
                           low: (Double, Double)? = nil, landing: (Double, Double)? = nil,
                           nextCheckIn: TimeInterval = 15 * 60) -> String {
        let suggestion = kind.map {
            #"{"kind":"\#($0)","grams":15,"units":\#(units),"refusalCode":null,"targetMmol":6.0,"isf":2.0,"minWithCarbs":4.4}"#
        } ?? "null"
        func point(_ p: (Double, Double)?) -> String {
            p.map { #"{"at":"\#(BackendDate.format(now.addingTimeInterval($0.0)))","mmol":\#($0.1)}"# } ?? "null"
        }
        return """
        {"state":"\(state)","reason":"\(reason)","suggestion":\(suggestion),"low":\(point(low)),"landing":\(point(landing)),
         "iob":1.2,"cob":30,"nextCheckAt":"\(BackendDate.format(now.addingTimeInterval(nextCheckIn)))","activityEstimate":"LEARNED"}
        """
    }

    private func glance(mmol: Double = 6.8, readingAge: TimeInterval = 120, trend: Int? = 3, libre: Bool = true,
                        stale: String = "NONE", prediction: String = "6.2", strip: String = "null") throws -> WatchGlance {
        let at = Int64(now.addingTimeInterval(-readingAge).timeIntervalSince1970 * 1000)
        let json = """
        {"reading":{"mmol":\(mmol),"at":\(at),"trend":\(trend.map(String.init) ?? "null"),"direction":null,"libre":\(libre)},
         "staleCause":"\(stale)","twoHourPredictionMmol":\(prediction),"watch":\(strip)}
        """
        return try JSONDecoder().decode(WatchGlance.self, from: Data(json.utf8))
    }

    private func present(_ g: WatchGlance, unit: String = "mmol/L", fetchedAgo: TimeInterval = 60) -> GlancePresentation {
        GlancePresentation(glance: g, now: now, fetchedAt: now.addingTimeInterval(-fetchedAgo), unit: unit)
    }

    // MARK: tests

    func testFreshMmolReading() throws {
        let p = present(try glance())
        XCTAssertEqual(p.valueText, "6.8")
        XCTAssertEqual(p.arrow, "→")
        XCTAssertEqual(p.unitLabel, "mmol/L")
        XCTAssertEqual(p.predictionText, "6.2")
        XCTAssertFalse(p.isStale)
        XCTAssertEqual(p.rangeColor, .inRange)
        XCTAssertNil(p.stale)
        XCTAssertNil(p.strip)
    }

    func testOldReadingIsStaleAndHidesPredictionAndStrip() throws {
        let p = present(try glance(mmol: 3.2, readingAge: 16 * 60,
                                   strip: stripJSON(state: "URGENT_LOW", reason: "LOW_NOW", kind: "CARBS")))
        XCTAssertTrue(p.isStale)
        XCTAssertNil(p.predictionText)
        XCTAssertNil(p.strip)
        XCTAssertEqual(p.rangeColor, .none)
    }

    func testUpstreamDownShowsStaleBanner() throws {
        let p = present(try glance(stale: "UPSTREAM_DOWN"))
        XCTAssertTrue(p.isStale)
        XCTAssertEqual(p.stale?.title, "LibreLinkUp isn't responding")
        XCTAssertEqual(p.stale?.detail, LibreStaleCause.upstreamDown.detail(lastReading: now.addingTimeInterval(-120), now: now))
        XCTAssertEqual(p.stale?.urgent, false)
    }

    func testExpiredDoseSuggestionHidesStrip() throws {
        let p = present(try glance(mmol: 13, strip: stripJSON(state: "URGENT_HIGH", reason: "HIGH_FORECAST", kind: "INSULIN",
                                                              units: "1.5", landing: (14_400, 14.2), nextCheckIn: -60)))
        XCTAssertNil(p.strip)
    }

    func testOldFetchHidesStrip() throws {
        // The phone hides a strip whose calculation is over 10 min old; a cached complication must too.
        let p = present(try glance(strip: stripJSON(state: "CALM", reason: "WATCHING", landing: (3_600, 7.0))),
                        fetchedAgo: 11 * 60)
        XCTAssertNil(p.strip)
    }

    func testStripTextMatchesPhone() throws {
        let g = try glance(mmol: 3.2, strip: stripJSON(state: "URGENT_LOW", reason: "LOW_NOW", kind: "CARBS"))
        let p = present(g)
        let strip = try XCTUnwrap(g.watch)
        XCTAssertEqual(p.strip?.title, WatchStripText.headline(strip, unit: "mmol/L"))
        XCTAssertEqual(p.strip?.detail, WatchStripText.detail(strip, unit: "mmol/L"))
        XCTAssertEqual(p.strip?.urgent, true)
        XCTAssertEqual(p.rangeColor, .urgent)
    }

    func testCalmStripIsNotUrgent() throws {
        let p = present(try glance(strip: stripJSON(state: "CALM", reason: "WATCHING", landing: (3_600, 7.0))))
        XCTAssertEqual(p.strip?.urgent, false)
    }

    func testMgdlUserSeesMgdlEverywhere() throws {
        let p = present(try glance(strip: stripJSON(state: "URGENT_LOW", reason: "FORECAST_LOW", kind: "CARBS",
                                                    low: (1_800, 3.6))), unit: "mg/dL")
        XCTAssertEqual(p.valueText, "123")
        XCTAssertEqual(p.predictionText, "112")
        XCTAssertEqual(p.unitLabel, "mg/dL")
        XCTAssertTrue(p.strip?.title.contains("mg/dL") ?? false, p.strip?.title ?? "no strip")
    }

    func testRangeColors() throws {
        XCTAssertEqual(present(try glance(mmol: 3.4)).rangeColor, .urgent)
        XCTAssertEqual(present(try glance(mmol: 3.8)).rangeColor, .low)
        XCTAssertEqual(present(try glance(mmol: 10.0)).rangeColor, .high)
        XCTAssertEqual(present(try glance(mmol: 14.0)).rangeColor, .urgent)
    }

    func testUnknownArrowShowsFlat() throws {
        XCTAssertEqual(present(try glance(trend: nil)).arrow, "→")
    }

    func testNoReading() throws {
        let json = #"{"reading":null,"staleCause":"NONE","twoHourPredictionMmol":null,"watch":null}"#
        let p = present(try JSONDecoder().decode(WatchGlance.self, from: Data(json.utf8)))
        XCTAssertEqual(p.valueText, "--")
        XCTAssertNil(p.readingAt)
        XCTAssertTrue(p.isStale)
    }
}
