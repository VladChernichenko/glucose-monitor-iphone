import XCTest
@testable import GlucoseMonitor

@MainActor
final class HypoPromptTests: XCTestCase {

    /// The backend speaks mmol/L only. A mg/dL user must see 63, not 3.5.
    func testTriggerGlucoseConvertsForMgdlDisplay() {
        let mmol = 3.5
        let displayed = GlucoseUnit.fromMmol(mmol, displayUnit: "mg/dL")
        XCTAssertEqual(displayed, 63.06, accuracy: 0.1)
    }

    func testTriggerGlucoseStaysUnchangedForMmolDisplay() {
        let displayed = GlucoseUnit.fromMmol(3.5, displayUnit: "mmol/L")
        XCTAssertEqual(displayed, 3.5, accuracy: 0.001)
    }

    func testPresetsAreTenFifteenTwenty() {
        XCTAssertEqual(BackendAPI.RescueCarbPresets.options, [10, 15, 20])
    }

    // MARK: - Fix-round-1 Finding A: double-tap race must not log the wrong amount

    /// The backend's confirm endpoint is idempotent on an already-CONFIRMED event: a second
    /// call replays the *first* winner's note and never re-reads `grams`. If `AppState` let two
    /// concurrent `confirmHypo` calls both reach the network, a patient who taps "10" then
    /// changes their mind to "20" before the sheet dismisses would have 10 g logged while
    /// believing they logged 20 g, with no error surfaced (the idempotent reply is a 200).
    /// `AppState.confirmHypo` closes this with an `isConfirmingHypo` guard that is atomic with
    /// respect to `@MainActor` serialization: only one call can ever pass the guard before the
    /// other observes it set, so only one of the two below is expected to reach the server.
    func testConfirmHypo_secondConcurrentCall_doesNotIssueSecondRequestToServer() async {
        GlucoseMonitorAPI.storeSessionTokens(accessToken: "test-token", refreshToken: nil)
        StubURLProtocol.reset()
        URLProtocol.registerClass(StubURLProtocol.self)
        defer {
            URLProtocol.unregisterClass(StubURLProtocol.self)
            StubURLProtocol.reset()
            GlucoseMonitorAPI.clearSession()
        }

        let confirmedJSON = """
        {"id":"evt-1","triggerGlucoseMmol":3.4,"state":"CONFIRMED",
         "noteId":"note-1","detectedAt":"2026-08-20T09:15:00","resolvedAt":"2026-08-20T09:16:00"}
        """.data(using: .utf8)!
        StubURLProtocol.enqueue(
            path: "/api/hypo-events/evt-1/confirm",
            .init(status: 200, body: confirmedJSON))

        let appState = AppState()
        appState.openHypoEvent = BackendAPI.HypoEvent(
            id: "evt-1", triggerGlucoseMmol: 3.4, state: "OPEN",
            noteId: nil, detectedAt: nil, resolvedAt: nil)

        // Two "taps" fired back-to-back, exactly as a shaky patient double-tapping would.
        async let first: Void = appState.confirmHypo(grams: 10)
        async let second: Void = appState.confirmHypo(grams: 20)
        _ = await (first, second)

        XCTAssertEqual(
            StubURLProtocol.hits(for: "/api/hypo-events/evt-1/confirm"), 1,
            "A second confirmHypo call while the first is in flight must not reach the confirm "
            + "endpoint - the idempotent server response would silently accept it while the "
            + "amount actually stored is the first request's, not the second's.")
    }

    // MARK: - Fix-round-1 Finding B: a failed poll must not dismiss an active prompt

    /// `refreshHypoEvents` runs on every `refreshAll()` cycle, including while the confirm sheet
    /// is already showing. A transient network failure must leave a currently-open prompt in
    /// place - clearing it would yank `.sheet(item:)` away from a patient mid-hypo with nothing
    /// acknowledged. Only a *successful* fetch that reports no open event may clear it.
    func testRefreshHypoEvents_networkFailure_leavesActivePromptUntouched() async {
        let appState = AppState()
        let activeEvent = BackendAPI.HypoEvent(
            id: "evt-active", triggerGlucoseMmol: 3.2, state: "OPEN",
            noteId: nil, detectedAt: nil, resolvedAt: nil)
        appState.openHypoEvent = activeEvent

        URLProtocol.registerClass(FailingURLProtocol.self)
        defer { URLProtocol.unregisterClass(FailingURLProtocol.self) }

        await appState.refreshHypoEvents()

        XCTAssertEqual(
            appState.openHypoEvent?.id, activeEvent.id,
            "A transient refresh failure must not clear an already-open hypo prompt - if this is "
            + "nil, the old `catch { openHypoEvent = nil }` regression is back.")
    }
}
