import XCTest
@testable import GlucoseMonitor

/// History-dose banner (Task 22): decoding the event and `payload.banner`, nothing preselected, the low
/// re-check (OK / AMBER / RED with a second tap), refusals and expiry.
@MainActor
final class HistoryBannerTests: XCTestCase {

    // MARK: - Fixtures

    private func local(_ s: String) -> Date { BackendAPI.parseBackendDate(s)! }
    private let validNow = BackendAPI.parseBackendDate("2026-10-31T12:05:00")!
    private let expiredNow = BackendAPI.parseBackendDate("2026-10-31T12:20:00")!

    private func planJSON(pause: String = #""pauseMinutes":15,"curve":[],"peak":10.2,"min":5.9,"reason":null"#) -> String {
        """
        {"carbs":{"low":40.5,"mid":45.0,"high":49.5},"fat":{"low":6.0,"mid":8.0,"high":10.0},
         "protein":{"low":18.0,"mid":20.0,"high":22.0},"fiber":{"low":3.6,"mid":4.0,"high":4.4},
         "gi":50.0,"patternLabel":"Slow Climb","doseUnits":4.0,"refusalCode":null,
         "pause":{\(pause)},"stale":false,"doseValidUntil":"2026-10-31T12:15:00"}
        """
    }

    private let bannerJSON = """
    {"modelUnits":4.0,"historyUnits":5.0,"deltaPct":25.0,"pauseMinutes":15,
     "episodes":{"count":3,"episodeIds":["e1","e2","e3"],"typicalDoseUnits":4.0,"peakLow":11.9,"peakHigh":13.3,"landing":9.4},
     "pendingIsfNote":"An ISF change for lunch is also suggested on the dashboard.",
     "modelCurve":[{"timestamp":"2026-10-31T12:05:00","predictedGlucose":7.3},{"timestamp":"2026-10-31T12:10:00","predictedGlucose":8.0}],
     "modelMin":6.1,"modelPeak":9.5,
     "historyCurve":[{"timestamp":"2026-10-31T12:05:00","predictedGlucose":7.2},{"timestamp":"2026-10-31T12:10:00","predictedGlucose":6.0}],
     "historyMin":4.2,"historyPeak":8.0,"historyLevel":"AMBER"}
    """

    private func payloadJSON(banner: String? = nil, plan: String? = nil, state: String = "PLANNED") -> String {
        """
        {"userMessageId":"u1","language":"en","state":"\(state)","description":"soup",
         "plannedAt":"2026-10-31T12:00:00","plan":\(plan ?? planJSON())\(banner.map { #","banner":\#($0)"# } ?? "")}
        """
    }

    private func decodePayload(_ json: String) throws -> BackendAPI.MealPlanPayload {
        try GlucoseMonitorAPI.jsonDecoder().decode(BackendAPI.MealPlanPayload.self, from: Data(json.utf8))
    }

    private func card(banner: String? = nil, plan: String? = nil, state: String = "PLANNED") throws -> MealPlanCard {
        try XCTUnwrap(MealPlanCard(messageId: "a1", payload: try decodePayload(payloadJSON(banner: banner ?? bannerJSON, plan: plan, state: state))))
    }

    private func recheck(level: String?, min: Double? = 4.0, refusal: String? = nil) -> BackendAPI.DoseRecheck {
        let curve = refusal == nil
            ? #"[{"timestamp":"2026-10-31T12:30:00","predictedGlucose":6.5},{"timestamp":"2026-10-31T15:00:00","predictedGlucose":\#(min ?? 4)}]"#
            : "[]"
        let json = #"{"curve":\#(curve),"min":\#(min.map { String($0) } ?? "null"),"level":\#(level.map { "\"\($0)\"" } ?? "null"),"refusalCode":\#(refusal.map { "\"\($0)\"" } ?? "null")}"#
        return try! GlucoseMonitorAPI.jsonDecoder().decode(BackendAPI.DoseRecheck.self, from: Data(json.utf8))
    }

    // MARK: - Fake service

    final class FakeService: AssistantChatService {
        var rechecks: [Result<BackendAPI.DoseRecheck, Error>] = []
        private(set) var recheckCalls: [(messageId: String, units: Double)] = []
        var scripted: [BackendAPI.AssistantEvent] = []
        func sendMessage(text: String?, photoJPEG: Data?, clientTime: String, timezone: String,
                         onEvent: @MainActor @escaping (BackendAPI.AssistantEvent) -> Void) async throws {
            for e in scripted { await onEvent(e) }
        }
        func fetchHistory(before: Date?, limit: Int) async throws -> [BackendAPI.ChatMessageDTO] { [] }
        func undo(messageId: String) async throws -> BackendAPI.AssistantUndoResult { throw URLError(.badServerResponse) }
        func fetchHitRate() async throws -> BackendAPI.AssistantHitRate { .init(hits: 0, checks: 0, percent: nil) }
        func mealPlanAction(messageId: String, action: BackendAPI.MealPlanAction, clientTime: String,
                            timezone: String) async throws -> BackendAPI.MealPlanActionResult { throw URLError(.badServerResponse) }
        func recheckDose(messageId: String, doseUnits: Double, clientTime: String,
                         timezone: String) async throws -> BackendAPI.DoseRecheck {
            recheckCalls.append((messageId, doseUnits))
            return try rechecks.removeFirst().get()
        }
    }

    /// A view model whose chat holds one streamed plan card "a1", with the banner event delivered after it.
    private func makeVM(_ fake: FakeService, banner: Bool = true) async throws -> ChatViewModel {
        let plan = try GlucoseMonitorAPI.jsonDecoder().decode(BackendAPI.MealPlan.self, from: Data(planJSON().utf8))
        var events: [BackendAPI.AssistantEvent] = [
            .plan(messageId: "a1", plan: plan, plannedAt: local("2026-10-31T12:00:00"),
                  doseValidUntil: local("2026-10-31T12:15:00"))]
        if banner {
            let line = #"{"type":"banner","messageId":"a1","banner":\#(bannerJSON)}"#
            events.append(try XCTUnwrap(BackendAPI.decodeAssistantEvent(line: line)))
        }
        events.append(.token("ok"))
        fake.scripted = events
        let vm = ChatViewModel(service: fake, pageSize: 3, now: { self.validNow },
                               timeZone: TimeZone(identifier: "Europe/Berlin")!)
        _ = await vm.send(text: "prepare me for: soup", photoJPEG: nil)
        return vm
    }

    private func currentCard(_ vm: ChatViewModel) -> MealPlanCard {
        guard let c = vm.items.compactMap({ item -> MealPlanCard? in if case .mealPlan(let c) = item.kind { return c }; return nil }).first else { fatalError("no card") }
        return c
    }

    // MARK: - Decoding

    func testDecodesBannerEvent() throws {
        let line = #"{"type":"banner","messageId":"a1","banner":\#(bannerJSON)}"#
        guard case .banner(let id, let b)? = BackendAPI.decodeAssistantEvent(line: line) else { return XCTFail("no banner event") }
        XCTAssertEqual(id, "a1")
        XCTAssertEqual(b.modelUnits, 4.0); XCTAssertEqual(b.historyUnits, 5.0); XCTAssertEqual(b.deltaPct, 25.0)
        XCTAssertEqual(b.episodes?.count, 3); XCTAssertEqual(b.episodes?.peakHigh, 13.3)
        XCTAssertEqual(b.pendingIsfNote, "An ISF change for lunch is also suggested on the dashboard.")
        XCTAssertEqual(b.modelCurve.count, 2); XCTAssertEqual(b.historyCurve.count, 2)
        XCTAssertEqual(b.historyLevel, "AMBER")
    }

    func testDecodesPayloadBannerAndInFlightFlag() throws {
        let p = try decodePayload(payloadJSON(banner: bannerJSON))
        XCTAssertEqual(p.banner?.historyUnits, 5.0)
        XCTAssertEqual(p.plan?.pause?.inFlight, false)
        let inFlight = try decodePayload(payloadJSON(plan: planJSON(pause: #""pauseMinutes":null,"curve":[],"inFlight":true"#)))
        XCTAssertEqual(inFlight.plan?.pause?.inFlight, true)
    }

    func testNoBannerKeyAndMalformedBannerKeepThePlan() throws {
        XCTAssertNil(try decodePayload(payloadJSON()).banner)
        let bad = try decodePayload(payloadJSON(banner: #"{"modelUnits":"x"}"#))
        XCTAssertNil(bad.banner)
        XCTAssertNotNil(bad.plan)
    }

    func testDecodesRecheckResponses() {
        XCTAssertEqual(recheck(level: "RED", min: 3.8).level, "RED")
        let refused = recheck(level: nil, min: nil, refusal: "DOSE_EXCEEDS_MAX_BOLUS")
        XCTAssertEqual(refused.refusalCode, "DOSE_EXCEEDS_MAX_BOLUS"); XCTAssertTrue(refused.curve.isEmpty); XCTAssertNil(refused.min)
    }

    func testRecheckRequestShape() throws {
        XCTAssertEqual(BackendAPI.recheckPath(messageId: "a1"), "/api/assistant/plans/a1/recheck")
        let body = try JSONSerialization.jsonObject(with: BackendAPI.recheckBody(doseUnits: 5, clientTime: "t", timezone: "z")) as? [String: Any]
        XCTAssertEqual(body?["doseUnits"] as? Double, 5); XCTAssertEqual(body?["timezone"] as? String, "z")
    }

    // MARK: - Nothing preselected

    func testNothingPreselectedDoseUnknownAndTookDisabled() throws {
        let c = try card()
        let state = HistoryBannerState.initial
        XCTAssertNotNil(HistoryBannerRules.activeBanner(c, now: validNow))
        XCTAssertTrue(HistoryBannerRules.awaitingChoice(c, state: state, now: validNow))
        XCTAssertNil(HistoryBannerRules.tookDose(c, state: state, now: validNow))
    }

    func testBannerTexts() throws {
        let b = try XCTUnwrap(try card().payload.banner)
        XCTAssertEqual(HistoryBannerRules.headline(b), "Your past similar meals needed more")
        XCTAssertEqual(HistoryBannerRules.comparisonLine(b), "Model 4.0 U \u{00B7} history 5.0 U (+25%)")
        XCTAssertEqual(HistoryBannerRules.episodesLine(b, unit: "mmol/L"),
                       "3 similar meals with ~4 U peaked 11.9\u{2013}13.3, landed ~9.4 mmol/L")
    }

    // MARK: - Choosing a dose

    func testOkAdoptsTheChosenDose() async throws {
        let fake = FakeService(); fake.rechecks = [.success(recheck(level: "OK", min: 5.5))]
        let vm = try await makeVM(fake)
        await vm.chooseBannerDose(messageId: "a1", units: 5.0)
        XCTAssertEqual(fake.recheckCalls.map(\.units), [5.0])
        let state = vm.bannerState("a1")
        XCTAssertEqual(HistoryBannerRules.adoptedDose(state), 5.0)
        XCTAssertEqual(HistoryBannerRules.tookDose(currentCard(vm), state: state, now: validNow), 5.0)
        XCTAssertFalse(HistoryBannerRules.awaitingChoice(currentCard(vm), state: state, now: validNow))
    }

    func testAmberAdoptsWithNoteAndBackResets() async throws {
        let fake = FakeService(); fake.rechecks = [.success(recheck(level: "AMBER", min: 4.3))]
        let vm = try await makeVM(fake)
        await vm.chooseBannerDose(messageId: "a1", units: 5.0)
        let state = vm.bannerState("a1")
        guard case .answered(_, let r, _) = state else { return XCTFail("not answered") }
        XCTAssertEqual(HistoryBannerRules.level(r), .amber)
        XCTAssertEqual(HistoryBannerRules.adoptedDose(state), 5.0) // "Took 5 U" is enabled with the amber note
        XCTAssertEqual(HistoryBannerRules.lowestText(r, unit: "mmol/L")?.hasPrefix("4.3 at "), true)
        vm.resetBanner(messageId: "a1")
        XCTAssertNil(HistoryBannerRules.adoptedDose(vm.bannerState("a1")))
    }

    func testRedNeedsSecondTap() async throws {
        let fake = FakeService(); fake.rechecks = [.success(recheck(level: "RED", min: 3.4))]
        let vm = try await makeVM(fake)
        await vm.chooseBannerDose(messageId: "a1", units: 5.0)
        // First tap: red card shown, nothing adopted, Took stays disabled.
        XCTAssertNil(HistoryBannerRules.adoptedDose(vm.bannerState("a1")))
        XCTAssertTrue(HistoryBannerRules.awaitingChoice(currentCard(vm), state: vm.bannerState("a1"), now: validNow))
        // Second explicit tap ("Use 5 U anyway").
        vm.confirmBannerRed(messageId: "a1")
        XCTAssertEqual(HistoryBannerRules.adoptedDose(vm.bannerState("a1")), 5.0)
        XCTAssertEqual(HistoryBannerRules.tookDose(currentCard(vm), state: vm.bannerState("a1"), now: validNow), 5.0)
    }

    func testConfirmDoesNothingWhenNotRed() async throws {
        let fake = FakeService(); fake.rechecks = [.success(recheck(level: "OK", min: 5.5))]
        let vm = try await makeVM(fake)
        vm.confirmBannerRed(messageId: "a1") // unanswered
        XCTAssertNil(HistoryBannerRules.adoptedDose(vm.bannerState("a1")))
    }

    func testRefusalKeepsUnknownDoseAndShowsReason() async throws {
        let fake = FakeService()
        fake.rechecks = [.success(recheck(level: nil, min: nil, refusal: "DOSE_EXCEEDS_MAX_BOLUS"))]
        let vm = try await makeVM(fake)
        await vm.chooseBannerDose(messageId: "a1", units: 5.0)
        guard case .unanswered(let notice) = vm.bannerState("a1") else { return XCTFail("adopted a refused dose") }
        XCTAssertEqual(notice, "5.0 U is above your maximum bolus. Pick a lower dose.")
        XCTAssertTrue(HistoryBannerRules.awaitingChoice(currentCard(vm), state: vm.bannerState("a1"), now: validNow))
    }

    func testUnknownLevelNeverAdopts() {
        guard case .unanswered = HistoryBannerRules.state(units: 5, recheck: recheck(level: "PURPLE")) else { return XCTFail("adopted") }
        guard case .unanswered = HistoryBannerRules.state(units: 5, recheck: recheck(level: nil)) else { return XCTFail("adopted") }
    }

    func testFailedRecheckKeepsUnanswered() async throws {
        let fake = FakeService(); fake.rechecks = [.failure(URLError(.notConnectedToInternet))]
        let vm = try await makeVM(fake)
        await vm.chooseBannerDose(messageId: "a1", units: 4.0)
        guard case .unanswered(let notice) = vm.bannerState("a1") else { return XCTFail("not unanswered") }
        XCTAssertNotNil(notice)
    }

    func testClockOffRejectionShowsServerMessageWithHint() async throws {
        let body = #"{"message":"Your phone's clock is off: 12 min ahead."}"#
        let fake = FakeService()
        fake.rechecks = [.failure(GlucoseMonitorAPI.APIError.httpStatus(400, body))]
        let vm = try await makeVM(fake)
        await vm.chooseBannerDose(messageId: "a1", units: 5.0)
        guard case .unanswered(let notice) = vm.bannerState("a1") else { return XCTFail("not unanswered") }
        XCTAssertTrue(notice?.contains("clock is off") == true)
        XCTAssertTrue(notice?.contains("Set Automatically") == true)
    }

    func testChoosingAgainReplacesTheEarlierAnswer() async throws {
        let fake = FakeService()
        fake.rechecks = [.success(recheck(level: "RED", min: 3.4)), .success(recheck(level: "OK", min: 5.5))]
        let vm = try await makeVM(fake)
        await vm.chooseBannerDose(messageId: "a1", units: 5.0)
        await vm.chooseBannerDose(messageId: "a1", units: 4.0)
        XCTAssertEqual(HistoryBannerRules.adoptedDose(vm.bannerState("a1")), 4.0)
    }

    // MARK: - Hiding the banner

    func testExpiredHidesBannerAndDose() throws {
        let c = try card()
        let adopted = HistoryBannerState.answered(units: 5, recheck: recheck(level: "OK", min: 5.5), confirmed: false)
        XCTAssertNil(HistoryBannerRules.activeBanner(c, now: expiredNow))
        XCTAssertNil(HistoryBannerRules.tookDose(c, state: adopted, now: expiredNow))
        XCTAssertNotNil(MealPlanRules.noDoseExplanation(c, now: expiredNow))
    }

    func testNoBannerWhenPreBolusInFlightStaleOrNotPlanned() throws {
        let inFlight = try card(plan: planJSON(pause: #""pauseMinutes":null,"curve":[],"inFlight":true"#))
        XCTAssertNil(HistoryBannerRules.activeBanner(inFlight, now: validNow))
        XCTAssertEqual(HistoryBannerRules.tookDose(inFlight, state: .initial, now: validNow), 4.0) // plain plan dose
        let took = try card(state: "TOOK")
        XCTAssertNil(HistoryBannerRules.activeBanner(took, now: validNow))
        let stale = try card(plan: planJSON().replacingOccurrences(of: #""stale":false"#, with: #""stale":true"#))
        XCTAssertNil(HistoryBannerRules.activeBanner(stale, now: validNow))
    }

    func testPlanWithoutBannerKeepsPlanDose() throws {
        let c = try XCTUnwrap(MealPlanCard(messageId: "a1", payload: try decodePayload(payloadJSON())))
        XCTAssertNil(HistoryBannerRules.activeBanner(c, now: validNow))
        XCTAssertEqual(HistoryBannerRules.tookDose(c, state: .initial, now: validNow), 4.0)
    }

    // MARK: - Live event reaches the card

    func testBannerEventAttachesToPlanCard() async throws {
        let vm = try await makeVM(FakeService())
        XCTAssertEqual(currentCard(vm).payload.banner?.historyUnits, 5.0)
        XCTAssertTrue(HistoryBannerRules.awaitingChoice(currentCard(vm), state: vm.bannerState("a1"), now: validNow))
    }
}
