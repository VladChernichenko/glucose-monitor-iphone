import XCTest
@testable import GlucoseMonitor

/// Meal plan card (Task 16): decoding the Task 15 contract, display rules and the
/// Took / Eating now / Not eating actions against a fake backend.
@MainActor
final class MealPlanCardTests: XCTestCase {

    // MARK: - Fixtures

    private let berlin = TimeZone(identifier: "Europe/Berlin")!

    /// Naive local wall time, as the backend sends it, parsed in the device zone (like the app does).
    private func local(_ s: String) -> Date { BackendAPI.parseBackendDate(s)! }

    /// Wall time in Berlin (the view model's zone in the action tests), independent of the simulator zone.
    private func berlinTime(_ s: String) -> Date {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX"); f.timeZone = berlin; f.dateFormat = "yyyy-MM-dd'T'HH:mm:ss"
        return f.date(from: s)!
    }

    private let planJSON = """
    {"carbs":{"low":40.5,"mid":45.0,"high":49.5},"fat":{"low":6.0,"mid":8.0,"high":10.0},
     "protein":{"low":18.0,"mid":20.0,"high":22.0},"fiber":{"low":3.6,"mid":4.0,"high":4.4},
     "gi":50.0,"patternLabel":"Slow Climb","doseUnits":4.5,"refusalCode":null,
     "pause":{"pauseMinutes":15,"curve":[
        {"timestamp":"2026-10-31T12:05:00","predictedGlucose":8.1,"predictedGlucoseLower":7.5,"predictedGlucoseUpper":8.7},
        {"timestamp":"2026-10-31T12:10:00","predictedGlucose":8.6}],
      "peak":10.2,"min":5.9,"reason":"A 15-min pause keeps the forecast closest to 5.5 mmol/L, between 5.9 and 10.2."},
     "stale":false,"doseValidUntil":"2026-10-31T12:15:00"}
    """

    private let stalePlanJSON = """
    {"carbs":{"low":55,"mid":68,"high":81},"fat":{"low":18,"mid":18,"high":18},"protein":{"low":20,"mid":20,"high":20},
     "fiber":{"low":4,"mid":4,"high":4},"gi":null,"patternLabel":null,"doseUnits":null,"refusalCode":null,"pause":null,"stale":true}
    """

    private let refusedPlanJSON = """
    {"carbs":{"low":36,"mid":40,"high":44},"fat":{"low":0,"mid":0,"high":0},"protein":{"low":0,"mid":0,"high":0},
     "fiber":{"low":0,"mid":0,"high":0},"gi":60,"patternLabel":"Fast Spike","doseUnits":null,
     "refusalCode":"GLUCOSE_BELOW_SAFE_THRESHOLD","pause":null,"stale":false}
    """

    private func payloadJSON(state: String, extra: String = "", plan: String? = nil) -> String {
        """
        {"userMessageId":"u1","language":"en","state":"\(state)","description":"chicken soup, rye bread 40 g",
         "plannedAt":"2026-10-31T12:00:00","meal":{"carbs":45.0,"fat":8.0,"protein":20.0,"fiber":4.0,"gi":50.0},
         "items":[{"name":"chicken soup"},{"name":"rye bread","grams":40.0}],
         "plan":\(plan ?? planJSON)\(extra)}
        """
    }

    private let tookExtra = """
    ,"tookAt":"2026-10-31T12:01:00","doseUnits":4.5,"pauseMinutes":15,"eatAt":"2026-10-31T12:16:00",
     "overdueAt":"2026-10-31T13:01:00","doseNoteId":"n1","doseSource":"PLAN","advisedDoseUnits":4.5
    """

    private func decodePayload(_ json: String) throws -> BackendAPI.MealPlanPayload {
        try GlucoseMonitorAPI.jsonDecoder().decode(BackendAPI.MealPlanPayload.self, from: Data(json.utf8))
    }

    private func decodePlan(_ json: String) throws -> BackendAPI.MealPlan {
        try GlucoseMonitorAPI.jsonDecoder().decode(BackendAPI.MealPlan.self, from: Data(json.utf8))
    }

    private func card(_ json: String, id: String = "a1") throws -> MealPlanCard {
        try XCTUnwrap(MealPlanCard(messageId: id, payload: try decodePayload(json)))
    }

    // MARK: - Decoding

    func testPlanEventDecodesWithMessageIdAndPlan() throws {
        let line = #"{"type":"plan","messageId":"a1","plannedAt":"2026-10-31T12:00:00","doseValidUntil":"2026-10-31T12:15:00","plan":"#
            + planJSON.replacingOccurrences(of: "\n", with: "") + "}"
        guard case .plan(let messageId, let plan, let plannedAt, let validUntil)? = BackendAPI.decodeAssistantEvent(line: line) else {
            return XCTFail("plan event not decoded")
        }
        XCTAssertEqual(messageId, "a1")
        XCTAssertEqual(plannedAt, local("2026-10-31T12:00:00"))
        XCTAssertEqual(validUntil, local("2026-10-31T12:15:00"))
        XCTAssertEqual(plan.carbs, BackendAPI.NutritionRange(low: 40.5, mid: 45, high: 49.5))
        XCTAssertEqual(plan.doseUnits, 4.5)
        XCTAssertEqual(plan.pause?.pauseMinutes, 15)
        XCTAssertEqual(plan.pause?.curve.count, 2)
        XCTAssertEqual(plan.pause?.curve.first?.predictedGlucoseUpper, 8.7)
        XCTAssertEqual(plan.patternLabel, "Slow Climb")
        XCTAssertEqual(plan.doseValidUntil, local("2026-10-31T12:15:00"))
        XCTAssertFalse(plan.stale)
    }

    func testPlanEventWithoutPlanBodyIsIgnored() {
        XCTAssertNil(BackendAPI.decodeAssistantEvent(line: #"{"type":"plan","messageId":"a1"}"#))
    }

    func testDecodesPlannedPayload() throws {
        let p = try decodePayload(payloadJSON(state: "PLANNED"))
        XCTAssertEqual(p.phase, .planned)
        XCTAssertEqual(p.items?.map(\.name), ["chicken soup", "rye bread"])
        XCTAssertEqual(p.items?.last?.grams, 40)
        XCTAssertEqual(p.meal?.carbs, 45)
        XCTAssertEqual(p.plannedAt, local("2026-10-31T12:00:00"))
        XCTAssertNotNil(p.plan)
    }

    func testDecodesTookPayload() throws {
        let p = try decodePayload(payloadJSON(state: "TOOK", extra: tookExtra))
        XCTAssertEqual(p.phase, .took)
        XCTAssertEqual(p.tookAt, local("2026-10-31T12:01:00"))
        XCTAssertEqual(p.doseUnits, 4.5)
        XCTAssertEqual(p.pauseMinutes, 15)
        XCTAssertEqual(p.eatAt, local("2026-10-31T12:16:00"))
        XCTAssertEqual(p.doseSource, "PLAN")
    }

    func testDecodesEatenPayload() throws {
        let p = try decodePayload(payloadJSON(state: "EATEN", extra: tookExtra + #","eatenAt":"2026-10-31T12:16:30","mealNoteId":"n2","eatenMeal":{"carbs":50.0,"fat":8.0,"protein":20.0,"fiber":4.0,"gi":50.0}"#))
        XCTAssertEqual(p.phase, .eaten)
        XCTAssertEqual(p.eatenMeal?.carbs, 50)
        XCTAssertEqual(p.mealNoteId, "n2")
    }

    func testDecodesSkippedPayload() throws {
        let p = try decodePayload(payloadJSON(state: "SKIPPED", extra: #","skippedAt":"2026-10-31T12:03:00""#))
        XCTAssertEqual(p.phase, .skipped)
        XCTAssertEqual(p.skippedAt, local("2026-10-31T12:03:00"))
    }

    func testHistoryRowWithMealPlanIntentBecomesCardPlusExplanation() throws {
        let json = """
        [{"id":"a1","createdAt":"2026-10-31T11:00:05Z","role":"ASSISTANT","text":"Bread is most of the carbs.",
          "intent":"meal_plan","hasPhoto":false,"noteIds":[],"payload":\(payloadJSON(state: "PLANNED"))},
         {"id":"u1","createdAt":"2026-10-31T11:00:00Z","role":"USER","text":"prepare me for soup","intent":null,
          "hasPhoto":false,"noteIds":[]}]
        """
        let rows = try GlucoseMonitorAPI.jsonDecoder().decode([BackendAPI.ChatMessageDTO].self, from: Data(json.utf8))
        let items = ChatViewModel.items(fromNewestFirst: rows)
        XCTAssertEqual(items.count, 3)
        guard case .mealPlan(let c) = items[1].kind else { return XCTFail("expected a plan card") }
        XCTAssertEqual(c.messageId, "a1")
        XCTAssertEqual(items[2].kind, .assistant(text: "Bread is most of the carbs."))
    }

    // MARK: - Display rules

    func testRangeDisplayRoundsToWholeGrams() {
        let r = BackendAPI.NutritionRange(low: 40.5, mid: 45.0, high: 49.5)
        XCTAssertEqual(MealPlanRules.midText(r), "45 g")
        XCTAssertEqual(MealPlanRules.rangeText(r), "41\u{2013}50")
    }

    func testRangeHiddenWhenBandCollapses() {
        XCTAssertNil(MealPlanRules.rangeText(BackendAPI.NutritionRange(low: 18, mid: 18, high: 18)))
    }

    func testDoseShowsOneDecimal() {
        XCTAssertEqual(MealPlanRules.doseText(4), "4.0 U")
        XCTAssertEqual(MealPlanRules.doseText(4.5), "4.5 U")
    }

    func testFreshPlanOffersAdvisedDoseAndPause() throws {
        let c = try card(payloadJSON(state: "PLANNED"))
        let now = local("2026-10-31T12:05:00")
        XCTAssertEqual(MealPlanRules.advisedDose(c, now: now), 4.5)
        XCTAssertEqual(MealPlanRules.advisedPause(c, now: now), 15)
        XCTAssertNil(MealPlanRules.noDoseExplanation(c, now: now))
    }

    func testStalePlanShowsNutritionOnlyWithExplanation() throws {
        let c = try card(payloadJSON(state: "PLANNED", plan: stalePlanJSON))
        let now = local("2026-10-31T12:01:00")
        XCTAssertNil(MealPlanRules.advisedDose(c, now: now))
        XCTAssertNil(MealPlanRules.advisedPause(c, now: now))
        XCTAssertEqual(MealPlanRules.noDoseExplanation(c, now: now), MealPlanRules.staleText)
    }

    func testRefusedPlanShowsRefusalAndNoDose() throws {
        let c = try card(payloadJSON(state: "PLANNED", plan: refusedPlanJSON))
        let now = local("2026-10-31T12:01:00")
        XCTAssertNil(MealPlanRules.advisedDose(c, now: now))
        XCTAssertNil(MealPlanRules.advisedPause(c, now: now))
        XCTAssertEqual(MealPlanRules.noDoseExplanation(c, now: now),
                       MealPlanRules.refusalText("GLUCOSE_BELOW_SAFE_THRESHOLD"))
    }

    func testDoseExpiresAfterDoseValidUntil() throws {
        let c = try card(payloadJSON(state: "PLANNED"))
        XCTAssertEqual(MealPlanRules.advisedDose(c, now: local("2026-10-31T12:15:00")), 4.5, "valid up to the instant")
        let later = local("2026-10-31T12:15:01")
        XCTAssertNil(MealPlanRules.advisedDose(c, now: later), "an expired plan must not prefill the dose")
        XCTAssertNil(MealPlanRules.advisedPause(c, now: later))
        XCTAssertTrue(MealPlanRules.isExpired(c, now: later))
        XCTAssertEqual(MealPlanRules.noDoseExplanation(c, now: later), MealPlanRules.expiredText)
    }

    func testDoseValidUntilOnPayloadAlsoCounts() throws {
        let planNoValidity = planJSON.replacingOccurrences(of: #","doseValidUntil":"2026-10-31T12:15:00""#, with: "")
        let c = try card(payloadJSON(state: "PLANNED", extra: #","doseValidUntil":"2026-10-31T12:15:00""#, plan: planNoValidity))
        XCTAssertNil(MealPlanRules.advisedDose(c, now: local("2026-10-31T12:20:00")))
    }

    func testZeroDoseIsShownButCannotBeTakenAsAdvised() throws {
        let zero = planJSON.replacingOccurrences(of: #""doseUnits":4.5"#, with: #""doseUnits":0.0"#)
        let c = try card(payloadJSON(state: "PLANNED", plan: zero))
        let now = local("2026-10-31T12:05:00")
        XCTAssertEqual(MealPlanRules.advisedDose(c, now: now), 0)
        XCTAssertFalse(MealPlanRules.canTakeAdvised(c, now: now))
    }

    func testPeakLineUsesUserUnit() throws {
        let plan = try decodePlan(planJSON)
        XCTAssertEqual(MealPlanRules.peakLine(plan.pause!, unit: "mmol/L"), "Peak ~10.2 \u{00B7} lowest 5.9 mmol/L")
        XCTAssertEqual(MealPlanRules.peakLine(plan.pause!, unit: "mg/dL"), "Peak ~184 \u{00B7} lowest 106 mg/dL")
    }

    func testUserEnteredDoseIsLabelledNotAdvised() throws {
        let extra = tookExtra.replacingOccurrences(of: #""doseSource":"PLAN","advisedDoseUnits":4.5"#,
                                                   with: #""doseSource":"USER_ENTERED","advisedDoseUnits":null"#)
        let c = try card(payloadJSON(state: "TOOK", extra: extra, plan: stalePlanJSON))
        XCTAssertTrue(MealPlanRules.dosedLabel(c.payload).contains("logged, not advised"))
        let planned = try card(payloadJSON(state: "TOOK", extra: tookExtra))
        XCTAssertFalse(MealPlanRules.dosedLabel(planned.payload).contains("not advised"))
        XCTAssertTrue(MealPlanRules.dosedLabel(planned.payload).hasPrefix("4.5 U taken"))
    }

    func testReplanMessageListsItemsWithGrams() {
        let text = MealPlanRules.replanMessage([.init(name: "rye bread", grams: 40), .init(name: " chicken soup ", grams: nil),
                                                .init(name: "", grams: 10)])
        XCTAssertEqual(text, "prepare me for: rye bread 40 g, chicken soup")
    }

    // MARK: - Countdown and overdue (injected clock)

    func testCountdownUntilEatAt() throws {
        let p = try decodePayload(payloadJSON(state: "TOOK", extra: tookExtra))
        XCTAssertEqual(MealPlanRules.countdown(p, now: local("2026-10-31T12:09:18")), "06:42")
        XCTAssertNil(MealPlanRules.countdown(p, now: local("2026-10-31T12:16:00")), "at eatAt it switches to Eating now")
    }

    func testAmberOnlyAfterTookAtPlusPausePlus45() throws {
        let p = try decodePayload(payloadJSON(state: "TOOK", extra: tookExtra))
        XCTAssertFalse(MealPlanRules.isOverdue(p, now: local("2026-10-31T13:01:00")))
        XCTAssertTrue(MealPlanRules.isOverdue(p, now: local("2026-10-31T13:01:01")))
    }

    func testNotOverdueOnceEatenOrSkipped() throws {
        let late = local("2026-10-31T15:00:00")
        XCTAssertFalse(MealPlanRules.isOverdue(try decodePayload(payloadJSON(state: "EATEN", extra: tookExtra)), now: late))
        XCTAssertFalse(MealPlanRules.isOverdue(try decodePayload(payloadJSON(state: "SKIPPED", extra: tookExtra)), now: late))
    }

    func testPreBolusCountdownLabel() {
        let t = Date(timeIntervalSince1970: 1000)
        XCTAssertEqual(PreBolusTimer.countdownLabel(until: t, now: t.addingTimeInterval(-402)), "06:42")
        XCTAssertNil(PreBolusTimer.countdownLabel(until: t, now: t))
    }

    // MARK: - Actions

    private func makeVM(_ fake: ChatViewModelTests.FakeAssistantService, now: Date) -> ChatViewModel {
        ChatViewModel(service: fake, pageSize: 50, now: { now }, timeZone: berlin)
    }

    private func streamPlan(_ vm: ChatViewModel, _ fake: ChatViewModelTests.FakeAssistantService) async throws {
        fake.scriptedEvents = [.plan(messageId: "a1", plan: try decodePlan(planJSON), plannedAt: nil, doseValidUntil: nil),
                               .token("Bread is most of the carbs."),
                               .done(.init(userMessageId: "u1", assistantMessageId: "a1", intent: "meal_plan"))]
        await vm.send(text: "prepare me for soup", photoJPEG: nil)
    }

    private func planCard(_ vm: ChatViewModel) -> MealPlanCard? {
        for item in vm.items { if case .mealPlan(let c) = item.kind { return c } }
        return nil
    }

    private func actionResult(_ state: String, extra: String) throws -> BackendAPI.MealPlanActionResult {
        let json = #"{"messageId":"a1","state":"\#(state)","noteId":"n1","payload":"# + payloadJSON(state: state, extra: extra) + "}"
        return try GlucoseMonitorAPI.jsonDecoder().decode(BackendAPI.MealPlanActionResult.self, from: Data(json.utf8))
    }

    func testStreamedPlanBecomesCardBeforeExplanation() async throws {
        let fake = ChatViewModelTests.FakeAssistantService()
        let vm = makeVM(fake, now: local("2026-10-31T12:00:00"))
        try await streamPlan(vm, fake)
        XCTAssertEqual(vm.items.count, 3)
        guard case .mealPlan(let c) = vm.items[1].kind else { return XCTFail("card missing") }
        XCTAssertEqual(c.messageId, "a1")
        XCTAssertEqual(c.payload.phase, .planned)
        XCTAssertEqual(vm.items[2].kind, .assistant(text: "Bread is most of the carbs."))
    }

    func testTookSendsPlanDoseAndPauseAndUpdatesCard() async throws {
        let fake = ChatViewModelTests.FakeAssistantService()
        let vm = makeVM(fake, now: berlinTime("2026-10-31T12:01:00"))
        try await streamPlan(vm, fake)
        fake.planResult = .success(try actionResult("TOOK", extra: tookExtra))
        var notesChanged = 0
        vm.onNotesChanged = { notesChanged += 1 }

        await vm.tookPlan(messageId: "a1", doseUnits: 4.5, pauseMinutes: 15)

        XCTAssertEqual(fake.planActions.count, 1)
        XCTAssertEqual(fake.planActions.first?.action, .took(doseUnits: 4.5, pauseMinutes: 15))
        XCTAssertEqual(fake.planActions.first?.clientTime, "2026-10-31T12:01:00")
        XCTAssertEqual(fake.planActions.first?.timezone, "Europe/Berlin")
        XCTAssertEqual(planCard(vm)?.payload.phase, .took)
        XCTAssertEqual(notesChanged, 1)
        XCTAssertFalse(vm.busyPlanIds.contains("a1"))
    }

    func testDoubleTapOnTookSendsOnce() async throws {
        let fake = ChatViewModelTests.FakeAssistantService()
        let vm = makeVM(fake, now: local("2026-10-31T12:01:00"))
        try await streamPlan(vm, fake)
        fake.planResult = .success(try actionResult("TOOK", extra: tookExtra))
        fake.planActionYields = true

        async let first: Void = vm.tookPlan(messageId: "a1", doseUnits: 4.5, pauseMinutes: 15)
        async let second: Void = vm.tookPlan(messageId: "a1", doseUnits: 4.5, pauseMinutes: 15)
        _ = await (first, second)

        XCTAssertEqual(fake.planActions.count, 1)
    }

    func testConflictRefreshesStateWithoutError() async throws {
        let fake = ChatViewModelTests.FakeAssistantService()
        let vm = makeVM(fake, now: local("2026-10-31T12:01:00"))
        try await streamPlan(vm, fake)
        fake.planResult = .failure(GlucoseMonitorAPI.APIError.httpStatus(409, #"{"message":"wrong state"}"#))
        let json = """
        [{"id":"a1","createdAt":"2026-10-31T11:00:05Z","role":"ASSISTANT","text":"Bread is most of the carbs.",
          "intent":"meal_plan","hasPhoto":false,"noteIds":[],"payload":\(payloadJSON(state: "TOOK", extra: tookExtra))}]
        """
        fake.pages = [try GlucoseMonitorAPI.jsonDecoder().decode([BackendAPI.ChatMessageDTO].self, from: Data(json.utf8))]
        let before = vm.items.count

        await vm.tookPlan(messageId: "a1", doseUnits: 4.5, pauseMinutes: 15)

        XCTAssertEqual(planCard(vm)?.payload.phase, .took, "409 means it was already taken: show that state")
        XCTAssertEqual(vm.items.count, before, "no error row for a 409")
        XCTAssertFalse(vm.items.contains { if case .error = $0.kind { return true } else { return false } })
    }

    func testClockRejectionShowsServerMessage() async throws {
        let fake = ChatViewModelTests.FakeAssistantService()
        let vm = makeVM(fake, now: local("2026-10-31T12:01:00"))
        try await streamPlan(vm, fake)
        fake.planResult = .failure(GlucoseMonitorAPI.APIError.httpStatus(
            400, #"{"status":400,"error":"Bad Request","message":"Your phone's clock is off: 12 min behind"}"#))

        await vm.tookPlan(messageId: "a1", doseUnits: 4.5, pauseMinutes: 15)

        XCTAssertEqual(vm.items.last?.kind,
                       .error("Your phone's clock is off: 12 min behind " + MealPlanRules.clockHint))
        XCTAssertEqual(planCard(vm)?.payload.phase, .planned)
        XCTAssertFalse(vm.busyPlanIds.contains("a1"))
    }

    func testOtherRejectionShowsServerMessageWithoutClockHint() {
        let err = GlucoseMonitorAPI.APIError.httpStatus(400, #"{"message":"Dose above your max bolus"}"#)
        XCTAssertEqual(MealPlanRules.classify(err), .rejected("Dose above your max bolus"))
        XCTAssertEqual(MealPlanRules.classify(URLError(.timedOut)), .failed("Couldn't save. \(URLError(.timedOut).localizedDescription)"))
    }

    func testClockRejectionOnSendShowsServerReason() async {
        let fake = ChatViewModelTests.FakeAssistantService()
        fake.sendError = GlucoseMonitorAPI.APIError.httpStatus(400, #"{"message":"Your phone's clock is off: 3 min ahead"}"#)
        let vm = makeVM(fake, now: local("2026-10-31T12:00:00"))
        await vm.send(text: "5u", photoJPEG: nil)
        XCTAssertEqual(vm.items.last?.kind, .error("Your phone's clock is off: 3 min ahead " + MealPlanRules.clockHint))
    }

    func testStreamedPlanTakesValidityFromEvent() async throws {
        let fake = ChatViewModelTests.FakeAssistantService()
        let vm = makeVM(fake, now: local("2026-10-31T12:00:00"))
        let noValidity = planJSON.replacingOccurrences(of: #","doseValidUntil":"2026-10-31T12:15:00""#, with: "")
        fake.scriptedEvents = [.plan(messageId: "a1", plan: try decodePlan(noValidity),
                                     plannedAt: local("2026-10-31T12:00:00"), doseValidUntil: local("2026-10-31T12:15:00")),
                               .done(.init(userMessageId: "u1", assistantMessageId: "a1", intent: "meal_plan"))]
        await vm.send(text: "prepare me for soup", photoJPEG: nil)
        let c = try XCTUnwrap(planCard(vm))
        XCTAssertEqual(MealPlanRules.advisedDose(c, now: local("2026-10-31T12:10:00")), 4.5)
        XCTAssertNil(MealPlanRules.advisedDose(c, now: local("2026-10-31T12:16:00")))
    }

    func testEatingSendsEditedMacros() async throws {
        let fake = ChatViewModelTests.FakeAssistantService()
        let vm = makeVM(fake, now: local("2026-10-31T12:16:00"))
        try await streamPlan(vm, fake)
        fake.planResult = .success(try actionResult("EATEN", extra: tookExtra))
        let macros = BackendAPI.MealMacros(carbs: 50, fat: nil, protein: nil, fiber: nil, gi: nil)

        await vm.eatPlan(messageId: "a1", macros: macros)

        XCTAssertEqual(fake.planActions.first?.action, .eating(macros))
        XCTAssertEqual(planCard(vm)?.payload.phase, .eaten)
    }

    func testSkipSendsSkip() async throws {
        let fake = ChatViewModelTests.FakeAssistantService()
        let vm = makeVM(fake, now: local("2026-10-31T12:02:00"))
        try await streamPlan(vm, fake)
        fake.planResult = .success(try actionResult("SKIPPED", extra: #","skippedAt":"2026-10-31T12:02:00""#))

        await vm.skipPlan(messageId: "a1")

        XCTAssertEqual(fake.planActions.first?.action, .skip)
        XCTAssertEqual(planCard(vm)?.payload.phase, .skipped)
    }

    func testReplanSendsPrepareMessage() async throws {
        let fake = ChatViewModelTests.FakeAssistantService()
        let vm = makeVM(fake, now: local("2026-10-31T12:02:00"))
        await vm.replan(items: [.init(name: "rye bread", grams: 60)])
        XCTAssertEqual(fake.sent.last?.text, "prepare me for: rye bread 60 g")
    }

    func testTookBodyEncodesContractFields() throws {
        let body = BackendAPI.mealPlanActionBody(.took(doseUnits: 4.5, pauseMinutes: 15),
                                                 clientTime: "2026-10-31T12:01:00", timezone: "Europe/Berlin")
        let obj = try XCTUnwrap(JSONSerialization.jsonObject(with: body) as? [String: Any])
        XCTAssertEqual(obj["doseUnits"] as? Double, 4.5)
        XCTAssertEqual(obj["pauseMinutes"] as? Int, 15)
        XCTAssertEqual(obj["clientTime"] as? String, "2026-10-31T12:01:00")
        XCTAssertEqual(obj["timezone"] as? String, "Europe/Berlin")
        XCTAssertEqual(BackendAPI.mealPlanActionPath(messageId: "a1", action: .took(doseUnits: 1, pauseMinutes: 0)),
                       "/api/assistant/plans/a1/took")
        XCTAssertEqual(BackendAPI.mealPlanActionPath(messageId: "a1", action: .skip), "/api/assistant/plans/a1/skip")
    }
}
