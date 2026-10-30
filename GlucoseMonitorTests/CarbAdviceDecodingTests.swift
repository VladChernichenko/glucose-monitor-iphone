import XCTest
@testable import GlucoseMonitor

/// Pins the `carbAdvice` JSON the backend sends inside the glucose-calculations response.
final class CarbAdviceDecodingTests: XCTestCase {

    private func response(carbAdvice: String?) throws -> BackendAPI.GlucoseCalculationsResponse {
        let advice = carbAdvice.map { ",\"carbAdvice\":\($0)" } ?? ""
        let json = """
        {"activeCarbsOnBoard":0,"activeInsulinOnBoard":1.2,"twoHourPrediction":5.0,"predictionTrend":"falling",
         "confidence":0.8\(advice)}
        """.data(using: .utf8)!
        return try JSONDecoder().decode(BackendAPI.GlucoseCalculationsResponse.self, from: json)
    }

    private let point = #"{"timestamp":"2026-10-31T19:00:00","predictedGlucose":5.9}"#

    func testDecodesTakeNow() throws {
        let r = try response(carbAdvice: """
        {"state":"TAKE_NOW","grams":15,"minWithout":4.0,"minWithoutAt":"2026-10-31T19:40:00","minWith":5.3,
         "curveWithout":[\(point)],"curveWith":[\(point),\(point)],"recheckAt":"2026-10-31T19:15:00","landingGrams":null}
        """)
        let a = try XCTUnwrap(r.carbAdvice)
        XCTAssertEqual(a.state, .takeNow)
        XCTAssertEqual(a.grams, 15)
        XCTAssertEqual(a.minWithout, 4.0, accuracy: 0.001)
        XCTAssertEqual(a.minWith ?? 0, 5.3, accuracy: 0.001)
        XCTAssertEqual(a.curveWithout.count, 1)
        XCTAssertEqual(a.curveWith?.count, 2)
        XCTAssertNil(a.landingGrams)
        XCTAssertEqual(a.recheckAt.timeIntervalSince(a.minWithoutAt), -25 * 60, accuracy: 1)
    }

    func testDecodesStillLanding() throws {
        let r = try response(carbAdvice: """
        {"state":"STILL_LANDING","grams":null,"minWithout":4.3,"minWithoutAt":"2026-10-31T19:40:00","minWith":null,
         "curveWithout":[\(point)],"curveWith":null,"recheckAt":"2026-10-31T19:20:00","landingGrams":15}
        """)
        let a = try XCTUnwrap(r.carbAdvice)
        XCTAssertEqual(a.state, .stillLanding)
        XCTAssertNil(a.grams)
        XCTAssertNil(a.minWith)
        XCTAssertNil(a.curveWith)
        XCTAssertEqual(a.landingGrams, 15)
    }

    func testAbsentOrNullFieldIsNil() throws {
        XCTAssertNil(try response(carbAdvice: nil).carbAdvice)
        XCTAssertNil(try response(carbAdvice: "null").carbAdvice)
    }

    func testUnknownStateIsNilAndDoesNotBreakTheResponse() throws {
        let r = try response(carbAdvice: """
        {"state":"SOMETHING_NEW","grams":15,"minWithout":4.0,"minWithoutAt":"2026-10-31T19:40:00","minWith":5.3,
         "curveWithout":[],"curveWith":[],"recheckAt":"2026-10-31T19:15:00"}
        """)
        XCTAssertNil(r.carbAdvice)
        XCTAssertEqual(r.twoHourPrediction, 5.0)
    }

    // MARK: Visibility and copy

    private func advice(_ state: String = "TAKE_NOW") throws -> BackendAPI.CarbAdvice {
        let grams = state == "TAKE_NOW" ? "15" : "null"
        let landing = state == "TAKE_NOW" ? "null" : "15"
        let r = try response(carbAdvice: """
        {"state":"\(state)","grams":\(grams),"minWithout":4.0,"minWithoutAt":"2026-10-31T19:40:00","minWith":5.3,
         "curveWithout":[],"curveWith":[],"recheckAt":"2026-10-31T19:20:00","landingGrams":\(landing)}
        """)
        return try XCTUnwrap(r.carbAdvice)
    }

    func testHiddenWhenStaleOrLowPromptShowing() throws {
        let a = try advice()
        XCTAssertNotNil(BackendAPI.CarbAdvice.visible(a, calculationsStale: false, hypoPromptOpen: false))
        XCTAssertNil(BackendAPI.CarbAdvice.visible(a, calculationsStale: true, hypoPromptOpen: false))
        XCTAssertNil(BackendAPI.CarbAdvice.visible(a, calculationsStale: false, hypoPromptOpen: true))
        XCTAssertNil(BackendAPI.CarbAdvice.visible(nil, calculationsStale: false, hypoPromptOpen: false))
    }

    func testHeadlineAndUnits() throws {
        XCTAssertEqual(ChatFormatting.carbAdviceHeadline(try advice(), unit: "mmol/L"), "Falling fast \u{2014} take 15 g now")
        let wait = ChatFormatting.carbAdviceHeadline(try advice("STILL_LANDING"), unit: "mmol/L")
        XCTAssertTrue(wait.hasPrefix("Wait \u{2014} the 15 g is still landing. No more carbs unless under 4.5 at "), wait)
        let mg = ChatFormatting.carbAdviceHeadline(try advice("STILL_LANDING"), unit: "mg/dL")
        XCTAssertTrue(mg.contains("under 81 at "), mg)
    }
}
