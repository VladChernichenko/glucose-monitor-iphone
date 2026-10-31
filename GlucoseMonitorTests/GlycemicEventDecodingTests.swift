import XCTest
@testable import GlucoseMonitor

/// Pins the JSON shapes the backend sends for glycemic events, decoded with the exact decoder the
/// network path uses. Unknown categories must decode (the server may add categories without a release).
final class GlycemicEventDecodingTests: XCTestCase {

    private let provisional = """
    {"id":"e1","category":"STRESS","detectorCategory":"STRESS","userLabel":null,"displayLabel":"Resistance?",
     "direction":"RISE","phase":"PROVISIONAL","state":"OPEN","onsetAt":"2026-09-30T11:40:00",
     "windowStart":"2026-09-30T11:55:00","windowEnd":"2026-09-30T12:45:00","resolvesAt":"2026-09-30T17:40:00",
     "detectedAt":"2026-09-30T12:46:00","resolvedAt":null,"confidence":0.5,"suppressed":false,
     "linkedEventId":null,"meanResidualMmol":3.1,"sigmaMultiple":4.2,
     "promptOptions":["STRESS","ABSORPTION_DELAY","LIPODYSTROPHY","UNLOGGED_FOOD"]}
    """

    func testDecodesProvisionalEvent() throws {
        let e = try GlucoseMonitorAPI.jsonDecoder().decode(BackendAPI.GlycemicEvent.self, from: Data(provisional.utf8))
        XCTAssertEqual(e.displayLabel, "Resistance?")
        XCTAssertTrue(e.isProvisional)
        XCTAssertTrue(e.isRise)
        XCTAssertFalse(e.isChild)
        XCTAssertEqual(e.promptOptions.count, 4)
        XCTAssertNotNil(e.resolvesAt)
        XCTAssertLessThan(e.onsetAt, e.windowStart)
    }

    func testUnknownCategoryStillDecodes() throws {
        let json = provisional.replacingOccurrences(of: "\"category\":\"STRESS\"", with: "\"category\":\"FUTURE_THING\"")
        let e = try GlucoseMonitorAPI.jsonDecoder().decode(BackendAPI.GlycemicEvent.self, from: Data(json.utf8))
        XCTAssertEqual(e.category, "FUTURE_THING")
        XCTAssertEqual(GlycemicCategory.buttonTitle("FUTURE_THING"), "Future Thing")
    }

    func testDecodesChildWithNulls() throws {
        let json = provisional
            .replacingOccurrences(of: "\"linkedEventId\":null", with: "\"linkedEventId\":\"p1\"")
            .replacingOccurrences(of: "\"resolvesAt\":\"2026-09-30T17:40:00\"", with: "\"resolvesAt\":null")
            .replacingOccurrences(of: "\"confidence\":0.5", with: "\"confidence\":null")
        let e = try GlucoseMonitorAPI.jsonDecoder().decode(BackendAPI.GlycemicEvent.self, from: Data(json.utf8))
        XCTAssertTrue(e.isChild)
        XCTAssertNil(e.resolvesAt)
        XCTAssertNil(e.confidence)
    }

    func testDecodesHistory() throws {
        let history = """
        [{"kind":"DETECTED","at":"2026-09-30T12:46:00","categoryBefore":null,"categoryAfter":"STRESS",
          "confidence":0.5,"actor":"SYSTEM","reason":"rule:R4"}]
        """
        let h = try GlucoseMonitorAPI.jsonDecoder().decode([BackendAPI.GlycemicEventHistoryEntry].self, from: Data(history.utf8))
        XCTAssertEqual(h.first?.reason, "rule:R4")
    }

    func testButtonTitlesAndAmountKinds() {
        XCTAssertEqual(GlycemicCategory.buttonTitle("UNLOGGED_FOOD"), "I ate")
        XCTAssertEqual(GlycemicCategory.buttonTitle("LIPODYSTROPHY"), "Injection site")
        XCTAssertTrue(GlycemicCategory.takesCarbs("UNLOGGED_FOOD"))
        XCTAssertFalse(GlycemicCategory.takesCarbs("STRESS"))
        XCTAssertTrue(GlycemicCategory.takesInsulin("UNLOGGED_INSULIN"))
    }

    func testPrompt204DecodesAsNil() async throws {
        GlucoseMonitorAPI.storeSessionTokens(accessToken: "test-token", refreshToken: nil)
        StubURLProtocol.reset()
        URLProtocol.registerClass(StubURLProtocol.self)
        defer {
            URLProtocol.unregisterClass(StubURLProtocol.self)
            StubURLProtocol.reset()
            GlucoseMonitorAPI.clearSession()
        }
        StubURLProtocol.enqueue(path: "/api/glycemic-events/prompt", .init(status: 204))
        let prompt = try await BackendAPI.fetchGlycemicPrompt()
        XCTAssertNil(prompt)
    }
}
