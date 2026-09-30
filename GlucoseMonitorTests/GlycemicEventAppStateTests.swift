import XCTest
@testable import GlucoseMonitor

@MainActor
final class GlycemicEventAppStateTests: XCTestCase {

    private func event(_ id: String) -> BackendAPI.GlycemicEvent {
        BackendAPI.GlycemicEvent(id: id, category: "UNLOGGED_FOOD", detectorCategory: "UNLOGGED_FOOD", userLabel: nil,
                                 displayLabel: "Unaccounted carbs", direction: "RISE", phase: "FINAL", state: "OPEN",
                                 onsetAt: Date().addingTimeInterval(-3600), windowStart: Date().addingTimeInterval(-3300),
                                 windowEnd: Date().addingTimeInterval(-600), resolvesAt: nil, confidence: 0.6,
                                 suppressed: false, linkedEventId: nil, meanResidualMmol: 3.0,
                                 promptOptions: ["UNLOGGED_FOOD", "STRESS", "ANAEROBIC_ACTIVITY"])
    }

    private let confirmedJSON = Data("""
    {"id":"g1","category":"STRESS","detectorCategory":"UNLOGGED_FOOD","userLabel":"STRESS","displayLabel":"Possible stress",
     "direction":"RISE","phase":"FINAL","state":"CONFIRMED","onsetAt":"2026-09-30T11:40:00",
     "windowStart":"2026-09-30T11:55:00","windowEnd":"2026-09-30T12:45:00","resolvesAt":null,
     "confidence":0.6,"suppressed":false,"linkedEventId":null,"meanResidualMmol":3.1,"promptOptions":["STRESS"]}
    """.utf8)

    override func setUp() {
        super.setUp()
        UserDefaults.standard.removeObject(forKey: AppState.glycemicSnoozeKey)
    }

    override func tearDown() {
        UserDefaults.standard.removeObject(forKey: AppState.glycemicSnoozeKey)
        URLProtocol.unregisterClass(StubURLProtocol.self)
        StubURLProtocol.reset()
        GlucoseMonitorAPI.clearSession()
        super.tearDown()
    }

    func testHypoPromptTakesPrecedence() {
        let s = AppState()
        s.glycemicPrompt = event("g1")
        XCTAssertEqual(s.visibleGlycemicPrompt?.id, "g1")
        s.openHypoEvent = BackendAPI.HypoEvent(id: "h1", triggerGlucoseMmol: 3.2, state: "OPEN",
                                               noteId: nil, detectedAt: nil, resolvedAt: nil)
        XCTAssertNil(s.visibleGlycemicPrompt, "a hypo always wins over an event question")
    }

    func testSnoozeHidesOnlyThisEventOnThisDevice() {
        let s = AppState()
        s.glycemicPrompt = event("g1")
        s.snoozeGlycemicPrompt()
        XCTAssertNil(s.visibleGlycemicPrompt)
        s.glycemicPrompt = event("g2")
        XCTAssertEqual(s.visibleGlycemicPrompt?.id, "g2")
    }

    func testFailedRefreshKeepsTheCurrentPrompt() async {
        let s = AppState()
        s.glycemicPrompt = event("g1")
        URLProtocol.registerClass(FailingURLProtocol.self)
        defer { URLProtocol.unregisterClass(FailingURLProtocol.self) }
        await s.refreshGlycemicPrompt()
        XCTAssertEqual(s.glycemicPrompt?.id, "g1")
    }

    func testFailedConfirmReleasesControlsAndKeepsPrompt() async {
        GlucoseMonitorAPI.storeSessionTokens(accessToken: "test-token", refreshToken: nil)
        StubURLProtocol.reset()
        URLProtocol.registerClass(StubURLProtocol.self)
        StubURLProtocol.enqueue(path: "/api/glycemic-events/g1/confirm", .jsonError(status: 500, message: "boom"))
        let s = AppState()
        s.glycemicPrompt = event("g1")
        let ok = await s.answerGlycemicPrompt(category: "STRESS")
        XCTAssertFalse(ok)
        XCTAssertFalse(s.isAnsweringGlycemicPrompt, "controls must come back after a failure")
        XCTAssertEqual(s.glycemicPrompt?.id, "g1")
    }

    func testDoubleTapConfirmsOnce() async {
        GlucoseMonitorAPI.storeSessionTokens(accessToken: "test-token", refreshToken: nil)
        StubURLProtocol.reset()
        URLProtocol.registerClass(StubURLProtocol.self)
        StubURLProtocol.enqueue(path: "/api/glycemic-events/g1/confirm", .init(status: 200, body: confirmedJSON))
        let s = AppState()
        s.glycemicPrompt = event("g1")
        async let a: Bool = s.answerGlycemicPrompt(category: "STRESS")
        async let b: Bool = s.answerGlycemicPrompt(category: "UNLOGGED_FOOD")
        _ = await (a, b)
        XCTAssertEqual(StubURLProtocol.hits(for: "/api/glycemic-events/g1/confirm"), 1)
        XCTAssertNil(s.glycemicPrompt)
    }
}
