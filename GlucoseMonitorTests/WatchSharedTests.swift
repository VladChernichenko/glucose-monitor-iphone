import XCTest
@testable import GlucoseMonitor

/// Pins the code the phone shares with the Apple Watch: trend tables (identical to the backend's
/// `PhoneTrendParity`), the glance JSON, the phone→watch handoff messages and the dose-expiry rule.
final class WatchSharedTests: XCTestCase {

    // MARK: trend arrows

    func testLibreArrows() {
        let expected = [1: "↓↓", 2: "↘", 3: "→", 4: "↗", 5: "↑↑", 0: "?", 6: "?"]
        for (trend, arrow) in expected {
            XCTAssertEqual(TrendArrow.arrow(trend: trend, direction: "SingleUp", libreEntry: true), arrow, "trend \(trend)")
        }
        XCTAssertEqual(TrendArrow.arrow(trend: nil, direction: "Flat", libreEntry: true), "?")
    }

    func testNightscoutArrows() {
        let expected = ["DoubleUp": "↑↑", "SingleUp": "↑", "FortyFiveUp": "↗", "Flat": "→",
                        "FortyFiveDown": "↘", "SingleDown": "↓", "DoubleDown": "↓↓",
                        "NOT COMPUTABLE": "→", "RATE OUT OF RANGE": "→", "Sideways": "→", "  ": "→",
                        " SingleUp ": "↑"]
        for (direction, arrow) in expected {
            XCTAssertEqual(TrendArrow.arrow(trend: 5, direction: direction, libreEntry: false), arrow, direction)
        }
        XCTAssertEqual(TrendArrow.arrow(trend: nil, direction: nil, libreEntry: false), "→")
    }

    func testVelocities() {
        let expected: [String: Double] = ["↑↑": 0.100, "↑": 0.067, "↗": 0.033, "→": 0, "↘": -0.033,
                                          "↓": -0.067, "↓↓": -0.100, "?": 0]
        for (arrow, v) in expected {
            XCTAssertEqual(TrendArrow.velocity(arrow), v, arrow)
        }
        XCTAssertEqual(TrendArrow.velocity(nil), 0)
    }

    func testDisplayArrowFallsBackToFlat() {
        XCTAssertEqual(TrendArrow.display("?"), "→")
        XCTAssertEqual(TrendArrow.display(nil), "→")
        XCTAssertEqual(TrendArrow.display(""), "→")
        XCTAssertEqual(TrendArrow.display("↗"), "↗")
    }

    // MARK: glance JSON

    func testGlanceDecodesBackendJSON() throws {
        let json = #"{"reading":{"mmol":6.8,"at":1795512143000,"trend":3,"direction":null,"libre":true},"staleCause":"NONE","twoHourPredictionMmol":6.2,"watch":null}"#
        let g = try JSONDecoder().decode(WatchGlance.self, from: Data(json.utf8))
        XCTAssertEqual(g.reading?.at, Date(timeIntervalSince1970: 1_795_512_143))
        XCTAssertEqual(g.reading?.mmol ?? 0, 6.8, accuracy: 1e-9)
        XCTAssertEqual(g.reading?.trend, 3)
        XCTAssertEqual(g.reading?.libre, true)
        XCTAssertEqual(g.staleCause, .none)
        XCTAssertEqual(g.twoHourPredictionMmol ?? 0, 6.2, accuracy: 1e-9)
        XCTAssertNil(g.watch)
    }

    func testGlanceDecodesEmptyGlance() throws {
        let json = #"{"reading":null,"staleCause":"UPSTREAM_DOWN","twoHourPredictionMmol":null,"watch":null}"#
        let g = try JSONDecoder().decode(WatchGlance.self, from: Data(json.utf8))
        XCTAssertNil(g.reading)
        XCTAssertEqual(g.staleCause, .upstreamDown)
    }

    func testGlanceRoundTripsWithStrip() throws {
        let json = """
        {"reading":{"mmol":3.2,"at":1795512143000,"trend":null,"direction":"Flat","libre":false},
         "staleCause":"NO_NEW_READINGS","twoHourPredictionMmol":4.1,
         "watch":{"state":"URGENT_LOW","reason":"LOW_NOW","suggestion":{"kind":"CARBS","grams":15,"units":null,
           "refusalCode":null,"targetMmol":null,"isf":null,"minWithCarbs":null},"low":{"at":"2026-10-31T19:40:00","mmol":3.6},
           "landing":null,"iob":1.2,"cob":30,"nextCheckAt":"2026-10-31T19:15:00","activityEstimate":"DEFAULT"}}
        """
        let first = try JSONDecoder().decode(WatchGlance.self, from: Data(json.utf8))
        XCTAssertEqual(first.watch?.reason, .lowNow)
        XCTAssertEqual(first.watch?.low?.at, BackendDate.parse("2026-10-31T19:40:00"))
        let again = try JSONDecoder().decode(WatchGlance.self, from: JSONEncoder().encode(first))
        XCTAssertEqual(again, first)
    }

    // MARK: handoff messages

    func testDecodeSession() {
        let m = WatchHandoff.Message.session(accessToken: "a", refreshToken: "r", backendURL: "https://x",
                                             displayUnit: "mg/dL", dataSource: "libre")
        XCTAssertEqual(WatchHandoff.Message.decode(m.encode()), m)
        XCTAssertEqual(m.encode()["v"] as? Int, 1)
    }

    func testDecodeSignedOut() {
        XCTAssertEqual(WatchHandoff.Message.decode(WatchHandoff.Message.signedOut.encode()), .signedOut)
    }

    func testDecodeDisplayUnitAndRequest() {
        XCTAssertEqual(WatchHandoff.Message.decode(WatchHandoff.Message.displayUnit("mmol/L").encode()), .displayUnit("mmol/L"))
        XCTAssertEqual(WatchHandoff.Message.decode(WatchHandoff.Message.requestSession.encode()), .requestSession)
    }

    func testDecodeUnknownKindIsNil() {
        XCTAssertNil(WatchHandoff.Message.decode(["v": 1, "kind": "bogus"]))
        XCTAssertNil(WatchHandoff.Message.decode(["v": 1, "kind": "session", "accessToken": "a"]))
    }

    // MARK: dose expiry

    func testSuggestionExpired() throws {
        let now = Date()
        let insulin = try strip(kind: "INSULIN", nextCheckAt: now.addingTimeInterval(-1))
        XCTAssertTrue(insulin.suggestionExpired(at: now))
        XCTAssertFalse(insulin.suggestionExpired(at: now.addingTimeInterval(-2)))
        let noAction = try strip(kind: "NO_ACTION", nextCheckAt: now.addingTimeInterval(-60))
        XCTAssertFalse(noAction.suggestionExpired(at: now))
    }

    private func strip(kind: String, nextCheckAt: Date) throws -> WatchStrip {
        let json = """
        {"state":"URGENT_HIGH","reason":"HIGH_FORECAST","suggestion":{"kind":"\(kind)","grams":null,"units":1.0,
         "refusalCode":null,"targetMmol":6.0,"isf":2.0,"minWithCarbs":null},"low":null,"landing":null,
         "iob":0.5,"cob":0,"nextCheckAt":"\(BackendDate.format(nextCheckAt))","activityEstimate":"LEARNED"}
        """
        return try JSONDecoder().decode(WatchStrip.self, from: Data(json.utf8))
    }
}
