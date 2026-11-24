import XCTest
@testable import GlucoseMonitor

/// When the Apple Watch taps the wrist: only for alerts that need the user to act, once per alert,
/// and again at each recheck while still low.
final class AlertBuzzPolicyTests: XCTestCase {

    private let t0 = Date(timeIntervalSince1970: 1_795_512_143)

    private func glance(at now: Date, state: String? = nil, reason: String? = nil, kind: String? = "CARBS",
                        nextCheckIn: TimeInterval = 15 * 60, stale: String = "NONE") throws -> WatchGlance {
        let strip: String
        if let state, let reason {
            let suggestion = kind.map {
                #"{"kind":"\#($0)","grams":15,"units":1.0,"refusalCode":null,"targetMmol":6.0,"isf":2.0,"minWithCarbs":4.4}"#
            } ?? "null"
            let point = #"{"at":"\#(BackendDate.format(now.addingTimeInterval(1_800)))","mmol":3.6}"#
            strip = """
            {"state":"\(state)","reason":"\(reason)","suggestion":\(suggestion),"low":\(point),"landing":\(point),
             "iob":1.2,"cob":30,"nextCheckAt":"\(BackendDate.format(now.addingTimeInterval(nextCheckIn)))","activityEstimate":"LEARNED"}
            """
        } else {
            strip = "null"
        }
        let at = Int64(now.addingTimeInterval(-60).timeIntervalSince1970 * 1000)
        let json = """
        {"reading":{"mmol":3.2,"at":\(at),"trend":3,"direction":null,"libre":true},
         "staleCause":"\(stale)","twoHourPredictionMmol":4.0,"watch":\(strip)}
        """
        return try JSONDecoder().decode(WatchGlance.self, from: Data(json.utf8))
    }

    private func run(_ memory: BuzzMemory, _ g: WatchGlance, _ now: Date) -> (Buzz?, BuzzMemory) {
        let r = AlertBuzzPolicy.decide(memory: memory, glance: g, now: now, unit: "mmol/L")
        return (r.buzz, r.memory)
    }

    func testLowNowBuzzesOnce() throws {
        let (first, m1) = run(BuzzMemory(), try glance(at: t0, state: "URGENT_LOW", reason: "LOW_NOW"), t0)
        XCTAssertNotNil(first)
        let later = t0.addingTimeInterval(300)
        let (second, _) = run(m1, try glance(at: later, state: "URGENT_LOW", reason: "LOW_NOW"), later)
        XCTAssertNil(second)
    }

    func testLowNowRebuzzesAtRecheck() throws {
        let (_, m1) = run(BuzzMemory(), try glance(at: t0, state: "URGENT_LOW", reason: "LOW_NOW"), t0)
        let atRecheck = t0.addingTimeInterval(15 * 60)
        let (again, m2) = run(m1, try glance(at: atRecheck, state: "URGENT_LOW", reason: "LOW_NOW"), atRecheck)
        XCTAssertNotNil(again, "still low at the recheck time")
        let soonAfter = atRecheck.addingTimeInterval(300)
        let (none, _) = run(m2, try glance(at: soonAfter, state: "URGENT_LOW", reason: "LOW_NOW"), soonAfter)
        XCTAssertNil(none, "the next recheck is 15 min after the last tap")
    }

    func testForecastLowAndHighForecastBuzz() throws {
        XCTAssertNotNil(run(BuzzMemory(), try glance(at: t0, state: "URGENT_LOW", reason: "FORECAST_LOW"), t0).0)
        XCTAssertNotNil(run(BuzzMemory(), try glance(at: t0, state: "URGENT_HIGH", reason: "HIGH_FORECAST", kind: "INSULIN"), t0).0)
    }

    func testShowOnlyReasonsNeverBuzz() throws {
        let showOnly = [("URGENT_LOW", "TREATING_LOW"), ("URGENT_LOW", "CARBS_LANDING"), ("URGENT_HIGH", "INSULIN_LANDING"),
                        ("URGENT_HIGH", "SMALL_RISE"), ("CALM", "WATCHING"), ("CALM", "DIP_AHEAD")]
        for (state, reason) in showOnly {
            XCTAssertNil(run(BuzzMemory(), try glance(at: t0, state: state, reason: reason, kind: "NO_ACTION"), t0).0, reason)
        }
    }

    func testLowNowAfterTreatingLowBuzzes() throws {
        let (_, m1) = run(BuzzMemory(), try glance(at: t0, state: "URGENT_LOW", reason: "TREATING_LOW", kind: "NO_ACTION"), t0)
        let later = t0.addingTimeInterval(300)
        XCTAssertNotNil(run(m1, try glance(at: later, state: "URGENT_LOW", reason: "LOW_NOW"), later).0)
    }

    func testStaleCauseBuzzesOncePerOutage() throws {
        let (first, m1) = run(BuzzMemory(), try glance(at: t0, stale: "UPSTREAM_DOWN"), t0)
        XCTAssertEqual(first?.title, "LibreLinkUp isn't responding")
        let t1 = t0.addingTimeInterval(300)
        let (second, m2) = run(m1, try glance(at: t1, stale: "UPSTREAM_DOWN"), t1)
        XCTAssertNil(second)
        let t2 = t1.addingTimeInterval(300)
        let (_, m3) = run(m2, try glance(at: t2), t2)
        let t3 = t2.addingTimeInterval(300)
        XCTAssertNotNil(run(m3, try glance(at: t3, stale: "UPSTREAM_DOWN"), t3).0, "a new outage taps again")
    }

    func testStaleGlanceNeverBuzzesForItsStrip() throws {
        let (buzz, _) = run(BuzzMemory(), try glance(at: t0, state: "URGENT_LOW", reason: "LOW_NOW", stale: "NO_NEW_READINGS"), t0)
        XCTAssertEqual(buzz?.title, "No new readings from Libre")
    }

    func testNoBuzzForPastRecheckAfterLongGap() throws {
        let memory = BuzzMemory(lastKey: nil, lastRecheckAt: nil, lastGlanceAt: t0.addingTimeInterval(-40 * 60))
        XCTAssertNil(run(memory, try glance(at: t0, state: "URGENT_LOW", reason: "LOW_NOW", nextCheckIn: -60), t0).0)
    }

    func testBuzzTextIsPhoneWording() throws {
        let g = try glance(at: t0, state: "URGENT_LOW", reason: "FORECAST_LOW")
        let strip = try XCTUnwrap(g.watch)
        let buzz = try XCTUnwrap(run(BuzzMemory(), g, t0).0)
        XCTAssertEqual(buzz.title, WatchStripText.headline(strip, unit: "mmol/L"))
        XCTAssertEqual(buzz.body, WatchStripText.detail(strip, unit: "mmol/L"))
    }

    func testRecordsGlanceTime() throws {
        XCTAssertEqual(run(BuzzMemory(), try glance(at: t0), t0).1.lastGlanceAt, t0)
    }
}
