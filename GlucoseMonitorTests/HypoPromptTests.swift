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
        async let first: Bool = appState.confirmHypo(grams: 10)
        async let second: Bool = appState.confirmHypo(grams: 20)
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

    // MARK: - Final review C1: a failed confirm must not brick the prompt

    /// `HypoPromptView` disables every submit control for the duration of one confirm and only a
    /// truthful failure signal hands them back. `confirmHypo` therefore has to *report* failure:
    /// when it silently returned `Void`, `isSubmitting` stayed set forever, and because `AppState`
    /// deliberately keeps `openHypoEvent` set on error the sheet kept the same view identity and
    /// the same `@State`. The patient was left with a "Please try again" banner over a prompt where
    /// nothing but "Not now" was tappable - and "Not now" dismisses server-side, then suppresses
    /// new prompts. 15 g of dextrose eaten, nothing recorded.
    func testConfirmHypo_serverFailure_reportsFailureAndKeepsThePromptOpen() async {
        GlucoseMonitorAPI.storeSessionTokens(accessToken: "test-token", refreshToken: nil)
        StubURLProtocol.reset()
        URLProtocol.registerClass(StubURLProtocol.self)
        defer {
            URLProtocol.unregisterClass(StubURLProtocol.self)
            StubURLProtocol.reset()
            GlucoseMonitorAPI.clearSession()
        }
        StubURLProtocol.enqueue(
            path: "/api/hypo-events/evt-1/confirm",
            .jsonError(status: 500, message: "boom"))

        let appState = AppState()
        appState.openHypoEvent = openEvent(id: "evt-1")

        let succeeded = await appState.confirmHypo(grams: 15)

        XCTAssertFalse(
            succeeded,
            "confirmHypo must report a failed attempt so the view can re-enable its controls. "
            + "Returning Void (or true) here is what bricked the prompt permanently.")
        XCTAssertEqual(
            appState.openHypoEvent?.id, "evt-1",
            "The prompt must stay up on failure so the amount is still one tap away.")
        XCTAssertNotNil(appState.errorMessage)
    }

    /// The end of the same story: after a transient failure the patient taps again and it works.
    /// This is what "recoverable" actually means - a second request must reach the server, which
    /// only happens if the in-flight guard was released on the failure path.
    func testConfirmHypo_retryAfterAFailure_reachesTheServerAndSucceeds() async {
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
            .jsonError(status: 500, message: "boom"),
            .init(status: 200, body: confirmedJSON))

        let appState = AppState()
        appState.openHypoEvent = openEvent(id: "evt-1")

        let first = await appState.confirmHypo(grams: 15)
        let second = await appState.confirmHypo(grams: 15)

        XCTAssertFalse(first)
        XCTAssertTrue(second, "The retry must succeed - the guard has to be released on failure.")
        XCTAssertEqual(
            StubURLProtocol.hits(for: "/api/hypo-events/evt-1/confirm"), 2,
            "The retry must actually reach the server. One hit means the in-flight guard was "
            + "never released and the rescue carbs are unrecoverable.")
        XCTAssertNil(appState.openHypoEvent)
    }

    // MARK: - Final review I3: a stale prompt must not be shown

    /// Defence in depth behind the server's age-out. A prompt whose trigger glucose is hours old
    /// no longer describes the patient, and confirming it writes a rescue-carb note at *now* -
    /// phantom fast carbs in COB, the Hovorka curve and the twin fit for a hypo that is over.
    func testStaleEventIsNotFresh() {
        XCTAssertFalse(
            AppState.isFresh(openEvent(id: "old", detectedAt: minutesAgo(61))),
            "An event older than \(AppState.hypoPromptMaxAgeMinutes) min must not be prompted.")
    }

    func testRecentEventIsFresh() {
        XCTAssertTrue(AppState.isFresh(openEvent(id: "new", detectedAt: minutesAgo(59))),
                      "An event inside the bound is a live prompt - this pins the boundary.")
    }

    /// Fail open, not closed: the server has already swept stale rows, and silently dropping a
    /// prompt we cannot date would lose a real hypo rather than merely showing an old one.
    func testEventWithNoDetectedAtIsTreatedAsFresh() {
        XCTAssertTrue(AppState.isFresh(openEvent(id: "undated", detectedAt: nil)))
        XCTAssertTrue(AppState.isFresh(openEvent(id: "garbled", detectedAt: "not-a-date")))
    }

    func testRefreshHypoEvents_skipsAStaleEventAndTakesTheFreshOne() async {
        GlucoseMonitorAPI.storeSessionTokens(accessToken: "test-token", refreshToken: nil)
        StubURLProtocol.reset()
        URLProtocol.registerClass(StubURLProtocol.self)
        defer {
            URLProtocol.unregisterClass(StubURLProtocol.self)
            StubURLProtocol.reset()
            GlucoseMonitorAPI.clearSession()
        }
        // Server order is detected_at DESC, but a stale row arriving first must not win just by
        // being first - `.first` used to take it unconditionally.
        let listJSON = """
        [{"id":"stale","triggerGlucoseMmol":3.1,"state":"OPEN","noteId":null,
          "detectedAt":"\(minutesAgo(600))","resolvedAt":null},
         {"id":"fresh","triggerGlucoseMmol":3.4,"state":"OPEN","noteId":null,
          "detectedAt":"\(minutesAgo(5))","resolvedAt":null}]
        """.data(using: .utf8)!
        StubURLProtocol.enqueue(path: "/api/hypo-events", .init(status: 200, body: listJSON))

        let appState = AppState()
        await appState.refreshHypoEvents()

        XCTAssertEqual(appState.openHypoEvent?.id, "fresh",
                       "A 10-hour-old prompt must be skipped in favour of the current one.")
    }

    // MARK: - Fixtures

    private func openEvent(id: String, detectedAt: String? = nil) -> BackendAPI.HypoEvent {
        BackendAPI.HypoEvent(
            id: id, triggerGlucoseMmol: 3.4, state: "OPEN",
            noteId: nil, detectedAt: detectedAt, resolvedAt: nil)
    }

    /// Backend `LocalDateTime` wire format: naive local wall time, no zone suffix.
    private func minutesAgo(_ minutes: Int) -> String {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = TimeZone.current
        f.dateFormat = "yyyy-MM-dd'T'HH:mm:ss"
        return f.string(from: Date().addingTimeInterval(-Double(minutes) * 60))
    }
}
