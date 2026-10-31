import XCTest
@testable import GlucoseMonitor

/// Mock-first tests for the dashboard chat: the backend is replaced by `FakeAssistantService`,
/// which replays scripted NDJSON events and history pages.
@MainActor
final class ChatViewModelTests: XCTestCase {

    // MARK: - Fake

    final class FakeAssistantService: AssistantChatService {
        var scriptedEvents: [BackendAPI.AssistantEvent] = []
        var sendError: Error?
        /// Called after each scripted event is delivered.
        var afterEvent: (() -> Void)?
        var pages: [[BackendAPI.ChatMessageDTO]] = []
        var undoResult = BackendAPI.AssistantUndoResult(messageId: "u1", noteIds: ["n1"], undone: true)
        private(set) var sent: [(text: String?, photo: Data?, clientTime: String, timezone: String)] = []
        private(set) var historyRequests: [(before: Date?, limit: Int)] = []
        private(set) var undone: [String] = []
        var hitRate: Result<BackendAPI.AssistantHitRate, Error> = .success(.init(hits: 0, checks: 0, percent: nil))

        private(set) var hitRateFetches = 0
        func fetchHitRate() async throws -> BackendAPI.AssistantHitRate { hitRateFetches += 1; return try hitRate.get() }

        func sendMessage(text: String?, photoJPEG: Data?, clientTime: String, timezone: String,
                         onEvent: @MainActor @escaping (BackendAPI.AssistantEvent) -> Void) async throws {
            sent.append((text, photoJPEG, clientTime, timezone))
            for e in scriptedEvents { await onEvent(e); afterEvent?() }
            if let sendError { throw sendError }
        }

        func fetchHistory(before: Date?, limit: Int) async throws -> [BackendAPI.ChatMessageDTO] {
            historyRequests.append((before, limit))
            return pages.isEmpty ? [] : pages.removeFirst()
        }

        func undo(messageId: String) async throws -> BackendAPI.AssistantUndoResult {
            undone.append(messageId)
            return undoResult
        }

        func recheckDose(messageId: String, doseUnits: Double, clientTime: String,
                         timezone: String) async throws -> BackendAPI.DoseRecheck { throw URLError(.badServerResponse) }

        var planResult: Result<BackendAPI.MealPlanActionResult, Error> = .failure(URLError(.badServerResponse))
        /// Suspends inside the call so a second tap can arrive while the first is in flight.
        var planActionYields = false
        private(set) var planActions: [(messageId: String, action: BackendAPI.MealPlanAction, clientTime: String, timezone: String)] = []

        func mealPlanAction(messageId: String, action: BackendAPI.MealPlanAction, clientTime: String,
                            timezone: String) async throws -> BackendAPI.MealPlanActionResult {
            planActions.append((messageId, action, clientTime, timezone))
            if planActionYields { try? await Task.sleep(nanoseconds: 50_000_000) }
            return try planResult.get()
        }
    }

    private func row(_ id: String, _ t: TimeInterval, role: String = "USER", text: String? = nil,
                     payload: BackendAPI.ChatMessagePayload? = nil) -> BackendAPI.ChatMessageDTO {
        BackendAPI.ChatMessageDTO(id: id, createdAt: Date(timeIntervalSince1970: t), role: role,
                                  text: text ?? id, intent: nil, hasPhoto: false, noteIds: [], payload: payload)
    }

    private let fixedNow = Date(timeIntervalSince1970: 1_793_358_000) // 2026-10-30T11:00:00Z

    private func makeVM(_ fake: FakeAssistantService, pageSize: Int = 3) -> ChatViewModel {
        ChatViewModel(service: fake, pageSize: pageSize, now: { self.fixedNow },
                      timeZone: TimeZone(identifier: "Europe/Berlin")!)
    }

    // MARK: - Carb advice

    func testTookFastCarbsSendsGramsFastThroughChatPath() async {
        let fake = FakeAssistantService()
        let vm = makeVM(fake)
        let ok = await vm.sendFastCarbs(grams: 15)
        XCTAssertEqual(fake.sent.map(\.text), ["15g fast"])
        XCTAssertTrue(ok)
    }

    func testTookFastCarbsReportsFailure() async {
        let fake = FakeAssistantService()
        fake.sendError = URLError(.notConnectedToInternet)
        let ok = await makeVM(fake).sendFastCarbs(grams: 15)
        XCTAssertFalse(ok, "a failed send must not dismiss the card")
    }

    // MARK: - Hit rate

    func testHitRateHiddenWhenNoChecks() async {
        let fake = FakeAssistantService()
        fake.hitRate = .success(.init(hits: 0, checks: 0, percent: nil))
        let vm = makeVM(fake)
        await vm.loadHitRate()
        XCTAssertNil(vm.hitRateLabel)
    }

    func testHitRatePillTextShowsRoundedPercent() async {
        let fake = FakeAssistantService()
        fake.hitRate = .success(.init(hits: 37, checks: 50, percent: 74.0))
        let vm = makeVM(fake)
        await vm.loadHitRate()
        XCTAssertEqual(vm.hitRateLabel, "Twin 74%")
    }

    func testHitRateFetchFailureKeepsPillHidden() async {
        let fake = FakeAssistantService()
        fake.hitRate = .failure(URLError(.notConnectedToInternet))
        let vm = makeVM(fake)
        await vm.loadHitRate()
        XCTAssertNil(vm.hitRateLabel)
    }

    func testHitRateLoadedOnAppearWithoutExpanding() async {
        let fake = FakeAssistantService()
        fake.hitRate = .success(.init(hits: 37, checks: 50, percent: 74.0))
        let vm = makeVM(fake)
        await vm.loadInitial()
        XCTAssertEqual(vm.hitRateLabel, "Twin 74%")
        await vm.loadInitial() // later appearances refresh it too
        XCTAssertEqual(fake.hitRateFetches, 2)
    }

    func testCompletedSendRefreshesHitRate() async {
        let fake = FakeAssistantService()
        let vm = makeVM(fake)
        await vm.loadInitial()
        XCTAssertNil(vm.hitRateLabel)
        fake.hitRate = .success(.init(hits: 1, checks: 1, percent: 100.0))
        await vm.send(text: "5u", photoJPEG: nil)
        XCTAssertEqual(vm.hitRateLabel, "Twin 100%")
    }

    // MARK: - History paging

    func testLoadInitialShowsNewestPageOldestFirst() async {
        let fake = FakeAssistantService()
        fake.pages = [[row("m3", 300), row("m2", 200), row("m1", 100)]] // server: newest first
        let vm = makeVM(fake)
        await vm.loadInitial()
        XCTAssertEqual(vm.items.map(\.id), ["m1", "m2", "m3"])
        XCTAssertNil(fake.historyRequests.first?.before)
        XCTAssertEqual(fake.historyRequests.first?.limit, 3)
        XCTAssertTrue(vm.hasMoreHistory)
    }

    func testLoadOlderPrependsAndKeepsAnchor() async {
        let fake = FakeAssistantService()
        fake.pages = [[row("m5", 500), row("m4", 400), row("m3", 300)],
                      [row("m2", 200), row("m1", 100)]]
        let vm = makeVM(fake)
        await vm.loadInitial()
        await vm.loadOlder()

        XCTAssertEqual(vm.items.map(\.id), ["m1", "m2", "m3", "m4", "m5"], "older page inserted before")
        XCTAssertEqual(vm.scrollAnchorId, "m3", "anchor stays on the message that was first before the load")
        XCTAssertEqual(fake.historyRequests.last?.before, Date(timeIntervalSince1970: 300), "pages by oldest createdAt")
        XCTAssertFalse(vm.hasMoreHistory, "short page means no more history")

        await vm.loadOlder()
        XCTAssertEqual(fake.historyRequests.count, 2, "no request once history is exhausted")
    }

    func testLoadOlderSkipsRowsAlreadyShown() async {
        let fake = FakeAssistantService()
        fake.pages = [[row("m4", 400), row("m3", 300), row("m2", 200)],
                      [row("m2", 200), row("m1", 100)]]
        let vm = makeVM(fake)
        await vm.loadInitial()
        await vm.loadOlder()
        XCTAssertEqual(vm.items.map(\.id), ["m1", "m2", "m3", "m4"])
    }

    func testHistoryLoggedRowBecomesLoggedEntryWithUndoState() async {
        let fake = FakeAssistantService()
        let loggedPayload = BackendAPI.ChatMessagePayload(type: "logged", noteIds: ["n1"], summary: "Logged 5 U.",
                                                          iob: 5, forecastMin: 5.8, userMessageId: "u1",
                                                          undone: nil, hypoEventId: nil)
        let userPayload = BackendAPI.ChatMessagePayload(type: nil, noteIds: nil, summary: nil, iob: nil,
                                                        forecastMin: nil, userMessageId: nil, undone: true,
                                                        hypoEventId: nil)
        fake.pages = [[row("a1", 200, role: "ASSISTANT", text: "Logged 5 U.", payload: loggedPayload),
                       row("u1", 100, text: "5u", payload: userPayload)]]
        let vm = makeVM(fake, pageSize: 50)
        await vm.loadInitial()
        XCTAssertEqual(vm.items.count, 2)
        guard case .logged(let entry) = vm.items[1].kind else { return XCTFail("expected logged row") }
        XCTAssertEqual(entry.undoMessageId, "u1")
        XCTAssertEqual(entry.forecastMin, 5.8)
        XCTAssertTrue(entry.undone)
    }

    // MARK: - Sending

    func testQuickLogShowsLoggedRowAndUndoMarksItUndone() async {
        let fake = FakeAssistantService()
        fake.scriptedEvents = [
            .logged(BackendAPI.AssistantLogged(noteIds: ["n1"], summary: "Logged 5 U + 50 g. IOB 5.3 U.", iob: 5.3, forecastMin: nil)),
            .done(BackendAPI.AssistantDone(userMessageId: "u1", assistantMessageId: "a1", intent: "quick_log")),
        ]
        var notesChanged = 0
        let vm = makeVM(fake)
        vm.onNotesChanged = { notesChanged += 1 }
        await vm.send(text: "5u 50g", photoJPEG: nil)

        XCTAssertEqual(fake.sent.first?.text, "5u 50g")
        XCTAssertEqual(fake.sent.first?.clientTime, "2026-10-30T12:00:00")
        XCTAssertEqual(fake.sent.first?.timezone, "Europe/Berlin")
        XCTAssertEqual(vm.items.count, 2)
        guard case .user(let text, _) = vm.items[0].kind else { return XCTFail("expected user bubble") }
        XCTAssertEqual(text, "5u 50g")
        guard case .logged(let entry) = vm.items[1].kind else { return XCTFail("expected logged row") }
        XCTAssertEqual(entry.undoMessageId, "u1")
        XCTAssertFalse(entry.undone)
        XCTAssertEqual(notesChanged, 1)
        XCTAssertFalse(vm.isSending)

        await vm.undo(itemId: vm.items[1].id)
        XCTAssertEqual(fake.undone, ["u1"])
        guard case .logged(let after) = vm.items[1].kind else { return XCTFail("expected logged row") }
        XCTAssertTrue(after.undone)
        XCTAssertEqual(notesChanged, 2)
    }

    func testQuestionTokensStreamIntoOneAssistantBubble() async {
        let fake = FakeAssistantService()
        fake.scriptedEvents = [.token("Your glucose "), .token("rose because"),
                               .done(BackendAPI.AssistantDone(userMessageId: "u1", assistantMessageId: "a1", intent: "question"))]
        let vm = makeVM(fake)
        await vm.send(text: "why high?", photoJPEG: nil)
        XCTAssertEqual(vm.items.count, 2)
        XCTAssertEqual(vm.items[1].kind, .assistant(text: "Your glucose rose because"))
        XCTAssertEqual(vm.lastMessageLine, "Your glucose rose because")
    }

    func testRejectedQuickLogRendersAsAssistantText() async {
        let fake = FakeAssistantService()
        fake.scriptedEvents = [.token("50 U looks too large to log."),
                               .done(BackendAPI.AssistantDone(userMessageId: "u1", assistantMessageId: "a1", intent: "quick_log_rejected"))]
        let vm = makeVM(fake)
        await vm.send(text: "50u", photoJPEG: nil)
        XCTAssertEqual(vm.items.last?.kind, .assistant(text: "50 U looks too large to log."))
    }

    func testUnknownEventsDoNotAddBubbles() async {
        let fake = FakeAssistantService()
        fake.scriptedEvents = [.citations([]), .token("ok"),
                               .done(BackendAPI.AssistantDone(userMessageId: nil, assistantMessageId: nil, intent: "question"))]
        let vm = makeVM(fake)
        await vm.send(text: "q", photoJPEG: nil)
        XCTAssertEqual(vm.items.count, 2)
        XCTAssertEqual(vm.items[1].kind, .assistant(text: "ok"))
    }

    private func citation(_ ref: Int) -> BackendAPI.AssistantCitation {
        BackendAPI.AssistantCitation(ref: ref, title: "T\(ref)", source: "ADA", year: 2024, url: URL(string: "https://a.org/\(ref)")!)
    }

    func testCitationsAttachUnderTheirReply() async {
        let fake = FakeAssistantService()
        fake.scriptedEvents = [.episodes([episode("e1")]), .citations([citation(1), citation(2)]), .token("Answer [1][2]."),
                               .done(BackendAPI.AssistantDone(userMessageId: "u1", assistantMessageId: "a1", intent: "question"))]
        let vm = makeVM(fake)
        await vm.send(text: "q1", photoJPEG: nil)
        fake.scriptedEvents = [.token("Second."), .done(BackendAPI.AssistantDone(userMessageId: "u2", assistantMessageId: "a2", intent: "question"))]
        await vm.send(text: "q2", photoJPEG: nil)
        // user, episodes, reply, chips, user, reply (the second reply has none)
        XCTAssertEqual(vm.items.count, 6)
        XCTAssertEqual(vm.items[2].kind, .assistant(text: "Answer [1][2]."))
        XCTAssertEqual(vm.items[3].kind, .citations([citation(1), citation(2)]))
        XCTAssertEqual(vm.items[5].kind, .assistant(text: "Second."))
        XCTAssertEqual(vm.lastMessageLine, "Second.")
    }

    func testHistoryPutsCitationsAfterTheStoredReply() throws {
        let json = #"""
        [{"id":"a1","createdAt":"2026-10-30T11:00:00Z","role":"ASSISTANT","text":"Answer [1].","intent":"question","hasPhoto":false,"noteIds":[],"payload":{"citations":[{"ref":1,"title":"T1","source":"ADA","year":2024,"url":"https://a.org/1"}]}},
         {"id":"u1","createdAt":"2026-10-30T10:59:00Z","role":"USER","text":"q","intent":"question","hasPhoto":false,"noteIds":[],"payload":null}]
        """#
        let rows = try GlucoseMonitorAPI.jsonDecoder().decode([BackendAPI.ChatMessageDTO].self, from: Data(json.utf8))
        let items = ChatViewModel.items(fromNewestFirst: rows)
        XCTAssertEqual(items.map(\.id), ["u1", "a1", "citations-a1"])
        XCTAssertEqual(items[2].kind, .citations([citation(1)]))
    }

    private func episode(_ id: String) -> BackendAPI.AssistantEpisode {
        let json = #"{"id":"\#(id)","kind":"MEAL","at":"2026-10-12T13:00","text":"soup","doseUnits":3.0,"peak":13.6}"#
        return try! JSONDecoder().decode(BackendAPI.AssistantEpisode.self, from: Data(json.utf8))
    }

    func testEpisodesAttachAboveTheReplyAndThinkingShowsUntilFirstToken() async {
        let fake = FakeAssistantService()
        fake.scriptedEvents = [.episodes([episode("e1"), episode("e2")]), .token("Because of the soup."),
                               .done(BackendAPI.AssistantDone(userMessageId: "u1", assistantMessageId: "a1", intent: "question"))]
        let vm = makeVM(fake)
        var thinking: [Bool] = []
        fake.afterEvent = { thinking.append(vm.items.last?.isThinking ?? false) }
        await vm.send(text: "why high after soup?", photoJPEG: nil)
        XCTAssertEqual(thinking, [true, false, false]) // still thinking after episodes, not after the token
        XCTAssertEqual(vm.items.count, 3)
        guard case .episodes(let list) = vm.items[1].kind else { return XCTFail("expected episodes row") }
        XCTAssertEqual(list.map(\.id), ["e1", "e2"])
        XCTAssertEqual(vm.items[2].kind, .assistant(text: "Because of the soup."))
        XCTAssertEqual(vm.lastMessageLine, "Because of the soup.")
    }

    private func historyRow(_ payloadJSON: String) throws -> BackendAPI.ChatMessageDTO {
        let json = #"{"id":"a1","createdAt":"2026-10-30T10:00:00Z","role":"ASSISTANT","text":"Answer","intent":"question","hasPhoto":false,"noteIds":[],"payload":"# + payloadJSON + "}"
        return try GlucoseMonitorAPI.jsonDecoder().decode(BackendAPI.ChatMessageDTO.self, from: Data(json.utf8))
    }

    func testHistoryQuestionReplyShowsEpisodesRowBeforeIt() throws {
        let r = try historyRow(#"{"type":"question","episodes":[{"id":"e1","kind":"MEAL","at":"2026-10-12T13:00","text":"soup"},{"id":"bad","kind":"SLEEP","at":"x"}]}"#)
        let items = ChatViewModel.items(fromNewestFirst: [r])
        XCTAssertEqual(items.count, 2)
        guard case .episodes(let list) = items[0].kind else { return XCTFail("expected episodes first") }
        XCTAssertEqual(list.map(\.id), ["e1"])
        XCTAssertEqual(items[1].kind, .assistant(text: "Answer"))
    }

    func testHistoryMalformedEpisodesStillShowTheReply() throws {
        for payload in [#"{"episodes":"oops"}"#, #"{"episodes":[{"nope":1}]}"#, #"{"episodes":[]}"#, #"{"type":"question"}"#] {
            let items = ChatViewModel.items(fromNewestFirst: [try historyRow(payload)])
            XCTAssertEqual(items.map(\.kind), [.assistant(text: "Answer")], payload)
        }
    }

    func testEmptyEpisodesAddNoRow() async {
        let fake = FakeAssistantService()
        fake.scriptedEvents = [.episodes([]), .token("ok")]
        let vm = makeVM(fake)
        await vm.send(text: "q", photoJPEG: nil)
        XCTAssertEqual(vm.items.count, 2)
    }

    func testEpisodeRowTextUsesUserUnit() {
        let e = episode("e1")
        XCTAssertEqual(EpisodeFormatting.row(e, unit: "mmol/L"), .init(text: "Oct 12 · soup · 3.0 U · peak 13.6", mark: false))
        XCTAssertEqual(EpisodeFormatting.row(e, unit: "mg/dL").text, "Oct 12 · soup · 3.0 U · peak 245")
        XCTAssertEqual(EpisodeFormatting.title([e]), "Similar meals")
    }

    func testErrorEventShowsErrorRow() async {
        let fake = FakeAssistantService()
        fake.scriptedEvents = [.error("Assistant reply failed")]
        let vm = makeVM(fake)
        await vm.send(text: "q", photoJPEG: nil)
        XCTAssertEqual(vm.items.last?.kind, .error("Assistant reply failed"))
        XCTAssertFalse(vm.isSending)
    }

    func testErrorAfterPartialReplyEndsSendingAndKeepsPartialText() async {
        // Backend contract: a failed question reply ends with `error` and no `done` after it.
        let fake = FakeAssistantService()
        fake.scriptedEvents = [.token("Your glucose "), .token("rose"), .error("Assistant reply failed")]
        let vm = makeVM(fake)
        await vm.send(text: "why high?", photoJPEG: nil)
        XCTAssertFalse(vm.isSending)
        XCTAssertEqual(vm.items.count, 3)
        XCTAssertEqual(vm.items[1].kind, .assistant(text: "Your glucose rose"))
        XCTAssertEqual(vm.items[2].kind, .error("Assistant reply failed"))
    }

    func testHistoryQuestionFailedRowIsMutedAssistantBubble() async {
        let fake = FakeAssistantService()
        fake.pages = [[BackendAPI.ChatMessageDTO(id: "a1", createdAt: Date(timeIntervalSince1970: 200), role: "ASSISTANT",
                                                 text: "Your glucose rose", intent: "question_failed",
                                                 hasPhoto: false, noteIds: [], payload: nil)]]
        let vm = makeVM(fake, pageSize: 50)
        await vm.loadInitial()
        XCTAssertEqual(vm.items.first?.kind, .assistant(text: "Your glucose rose"))
        XCTAssertEqual(vm.items.first?.isFailed, true)
    }

    func testConnectionLostMidStreamEndsSendingKeepsPartialAndShowsErrorRow() async {
        let fake = FakeAssistantService()
        fake.scriptedEvents = [.token("Your glucose")]
        fake.sendError = URLError(.networkConnectionLost)
        let vm = makeVM(fake)
        await vm.send(text: "why high?", photoJPEG: nil)
        XCTAssertFalse(vm.isSending)
        XCTAssertEqual(vm.items.count, 3)
        XCTAssertEqual(vm.items[1].kind, .assistant(text: "Your glucose"))
        guard case .error = vm.items[2].kind else { return XCTFail("expected error row") }
    }

    func testTransportFailureShowsErrorRow() async {
        let fake = FakeAssistantService()
        fake.sendError = URLError(.badServerResponse)
        let vm = makeVM(fake)
        await vm.send(text: "q", photoJPEG: nil)
        guard case .error = vm.items.last?.kind else { return XCTFail("expected error row") }
    }

    func testBlankMessageWithoutPhotoIsNotSent() async {
        let fake = FakeAssistantService()
        let vm = makeVM(fake)
        await vm.send(text: "   ", photoJPEG: nil)
        XCTAssertTrue(fake.sent.isEmpty)
        XCTAssertTrue(vm.items.isEmpty)
    }

    func testPhotoOnlyMessageSendsNoText() async {
        let fake = FakeAssistantService()
        fake.scriptedEvents = [.token("Looks like soup.")]
        let vm = makeVM(fake)
        await vm.send(text: "", photoJPEG: Data([1, 2, 3]))
        XCTAssertNil(fake.sent.first?.text)
        XCTAssertEqual(fake.sent.first?.photo, Data([1, 2, 3]))
        guard case .user(_, let hasPhoto) = vm.items[0].kind else { return XCTFail("expected user bubble") }
        XCTAssertTrue(hasPhoto)
    }

    // MARK: - Glycemic prompt

    private func promptEvent() -> BackendAPI.GlycemicEvent {
        BackendAPI.GlycemicEvent(id: "g1", category: "UNLOGGED_FOOD", detectorCategory: "UNLOGGED_FOOD", userLabel: nil,
                                 displayLabel: "Unexplained rise", direction: "RISE", phase: "PROVISIONAL", state: "OPEN",
                                 onsetAt: fixedNow.addingTimeInterval(-3000), windowStart: fixedNow.addingTimeInterval(-3000),
                                 windowEnd: fixedNow, resolvesAt: nil, confidence: nil, suppressed: false,
                                 linkedEventId: nil, meanResidualMmol: 3.2, promptOptions: ["UNLOGGED_FOOD", "STRESS"])
    }

    func testPendingGlycemicPromptRenderedAsBubble() async {
        let fake = FakeAssistantService()
        fake.pages = [[row("m1", 100)]]
        let vm = makeVM(fake)
        await vm.loadInitial()
        var answered: [(String, String?, Double?, Double?)] = []
        vm.onAnswerPrompt = { event, category, carbs, insulin in
            answered.append((event.id, category, carbs, insulin)); return true
        }

        vm.setPendingPrompt(promptEvent(), displayUnit: "mg/dL")

        // Pinned as the last bubble, in the user's unit, and shown in the peek line.
        guard case .glycemicPrompt(let event, let text) = vm.bubbles.last?.kind else { return XCTFail("expected prompt bubble") }
        XCTAssertEqual(event.id, "g1")
        XCTAssertTrue(text.contains("58 mg/dL"), text)
        XCTAssertEqual(vm.lastMessageLine, text)

        // A new user message does not push the prompt out of last place.
        await vm.send(text: "hi", photoJPEG: nil)
        guard case .glycemicPrompt = vm.bubbles.last?.kind else { return XCTFail("prompt must stay last") }

        await vm.answerPrompt(category: "UNLOGGED_FOOD", carbs: 30, insulin: nil)
        XCTAssertEqual(answered.count, 1)
        XCTAssertEqual(answered.first?.0, "g1")
        XCTAssertEqual(answered.first?.1, "UNLOGGED_FOOD")
        XCTAssertEqual(answered.first?.2, 30)
        XCTAssertNil(answered.first?.3)
        XCTAssertNil(vm.pendingPrompt)
        // Client-side confirmation bubble, nothing posted to the assistant.
        guard case .assistant(let confirmation) = vm.bubbles.last?.kind else { return XCTFail("expected confirmation") }
        XCTAssertTrue(confirmation.contains("I ate"), confirmation)
        XCTAssertEqual(fake.sent.count, 1)
    }

    func testFailedPromptAnswerKeepsPrompt() async {
        let vm = makeVM(FakeAssistantService())
        vm.onAnswerPrompt = { _, _, _, _ in false }
        vm.setPendingPrompt(promptEvent(), displayUnit: "mmol/L")
        await vm.answerPrompt(category: "STRESS", carbs: nil, insulin: nil)
        XCTAssertNotNil(vm.pendingPrompt)
        XCTAssertTrue(vm.items.isEmpty)
    }

    // MARK: - Units

    func testGlucoseShownInMgdlWhenUnitIsMgdl() {
        XCTAssertEqual(ChatFormatting.glucose(mmol: 7.9, unit: "mg/dL"), "142")
        XCTAssertEqual(ChatFormatting.glucose(mmol: 7.9, unit: "mmol/L"), "7.9")
    }

    func testLoggedSummaryForecastMinConvertedToMgdl() {
        let en = "Logged 5 U + 50 g. IOB 5.3 U, lowest 5.8 in the next 4 h."
        XCTAssertEqual(ChatFormatting.loggedSummary(en, forecastMin: 5.8, unit: "mg/dL"),
                       "Logged 5 U + 50 g. IOB 5.3 U, lowest 105 in the next 4 h.")
        XCTAssertEqual(ChatFormatting.loggedSummary(en, forecastMin: 5.8, unit: "mmol/L"), en)
        let ru = "Записано 5 ЕД. IOB 5 ЕД, минимум 6 в ближайшие 4 ч."
        XCTAssertEqual(ChatFormatting.loggedSummary(ru, forecastMin: 6.0, unit: "mg/dL"),
                       "Записано 5 ЕД. IOB 5 ЕД, минимум 108 в ближайшие 4 ч.")
        XCTAssertEqual(ChatFormatting.loggedSummary("Logged 5 U. IOB 5 U.", forecastMin: nil, unit: "mg/dL"),
                       "Logged 5 U. IOB 5 U.")
    }

    func testHeaderIobCobLine() {
        XCTAssertEqual(ChatFormatting.iobCob(iob: 4.12, cob: 32.4), "IOB 4.1 U · COB 32 g")
        XCTAssertEqual(ChatFormatting.iobCob(iob: nil, cob: nil), "IOB -- · COB --")
    }
}
