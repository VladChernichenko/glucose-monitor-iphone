import XCTest
@testable import GlucoseMonitor

/// Free-text event proposals ("hot shower"): the `proposal` stream event, the Confirm call,
/// "No" (local only), double-tap protection, a rejected clock, and `event_proposal` history rows.
@MainActor
final class EventProposalTests: XCTestCase {

    final class FakeService: AssistantChatService {
        var scriptedEvents: [BackendAPI.AssistantEvent] = []
        var pages: [[BackendAPI.ChatMessageDTO]] = []
        var confirmResult: Result<BackendAPI.EventConfirmResult, Error> = .failure(URLError(.badServerResponse))
        /// Suspends inside the call so a second tap can arrive while the first is in flight.
        var confirmYields = false
        private(set) var confirms: [(messageId: String, clientTime: String, timezone: String)] = []

        func sendMessage(text: String?, photoJPEG: Data?, clientTime: String, timezone: String,
                         onEvent: @MainActor @escaping (BackendAPI.AssistantEvent) -> Void) async throws {
            for e in scriptedEvents { await onEvent(e) }
        }
        func fetchHistory(before: Date?, limit: Int) async throws -> [BackendAPI.ChatMessageDTO] {
            pages.isEmpty ? [] : pages.removeFirst()
        }
        func undo(messageId: String) async throws -> BackendAPI.AssistantUndoResult { throw URLError(.badURL) }
        func fetchHitRate() async throws -> BackendAPI.AssistantHitRate { .init(hits: 0, checks: 0, percent: nil) }
        func mealPlanAction(messageId: String, action: BackendAPI.MealPlanAction, clientTime: String,
                            timezone: String) async throws -> BackendAPI.MealPlanActionResult { throw URLError(.badURL) }
        func recheckDose(messageId: String, doseUnits: Double, clientTime: String,
                         timezone: String) async throws -> BackendAPI.DoseRecheck { throw URLError(.badURL) }
        func confirmEvent(messageId: String, clientTime: String,
                          timezone: String) async throws -> BackendAPI.EventConfirmResult {
            confirms.append((messageId, clientTime, timezone))
            if confirmYields { try? await Task.sleep(nanoseconds: 50_000_000) }
            return try confirmResult.get()
        }
    }

    private let fixedNow = Date(timeIntervalSince1970: 1_793_358_000) // 2026-10-30T11:00:00Z
    private let berlin = TimeZone(identifier: "Europe/Berlin")!

    private func makeVM(_ fake: FakeService) -> ChatViewModel {
        ChatViewModel(service: fake, pageSize: 50, now: { self.fixedNow }, timeZone: berlin)
    }

    private func proposalCard(_ vm: ChatViewModel, _ id: String = "p1") -> EventProposalCard? {
        for item in vm.items where item.id == id {
            if case .eventProposal(let card) = item.kind { return card }
        }
        return nil
    }

    private func confirmed(_ id: String = "p1") -> BackendAPI.EventConfirmResult {
        let json = #"{"messageId":"\#(id)","state":"CONFIRMED","noteId":"n9","payload":{"state":"CONFIRMED","tags":["HOT_SHOWER"],"comment":"hot shower","noteId":"n9"}}"#
        return try! GlucoseMonitorAPI.jsonDecoder().decode(BackendAPI.EventConfirmResult.self, from: Data(json.utf8))
    }

    private func streamedProposal(_ fake: FakeService) async -> ChatViewModel {
        fake.scriptedEvents = [
            .proposal(messageId: "p1", tags: ["HOT_SHOWER", "SAUNA"], comment: "just had a hot shower"),
            .done(BackendAPI.AssistantDone(userMessageId: "u1", assistantMessageId: "p1", intent: "event_proposal"))]
        let vm = makeVM(fake)
        await vm.send(text: "just had a hot shower", photoJPEG: nil)
        return vm
    }

    // MARK: - Decoding

    func testProposalLineDecodes() {
        let line = #"{"type":"proposal","messageId":"p1","tags":["HOT_SHOWER","SAUNA"],"comment":"just had a hot shower"}"#
        XCTAssertEqual(BackendAPI.decodeAssistantEvent(line: line),
                       .proposal(messageId: "p1", tags: ["HOT_SHOWER", "SAUNA"], comment: "just had a hot shower"))
    }

    func testProposalWithoutMessageIdIsDropped() {
        XCTAssertNil(BackendAPI.decodeAssistantEvent(line: #"{"type":"proposal","tags":["HOT_SHOWER"]}"#))
    }

    func testProposalWithoutTagsOrCommentDecodesEmpty() {
        XCTAssertEqual(BackendAPI.decodeAssistantEvent(line: #"{"type":"proposal","messageId":"p1"}"#),
                       .proposal(messageId: "p1", tags: [], comment: nil))
    }

    func testConfirmRequestPathAndBody() throws {
        XCTAssertEqual(BackendAPI.eventConfirmPath(messageId: "p1"), "/api/assistant/events/p1/confirm")
        let body = try JSONSerialization.jsonObject(
            with: BackendAPI.eventConfirmBody(clientTime: "2026-10-30T12:00:00", timezone: "Europe/Berlin")) as? [String: String]
        XCTAssertEqual(body, ["clientTime": "2026-10-30T12:00:00", "timezone": "Europe/Berlin"])
    }

    // MARK: - Stream

    func testStreamedProposalBecomesABubbleWithTagsAndConfirm() async {
        let vm = await streamedProposal(FakeService())
        let card = proposalCard(vm)
        XCTAssertEqual(card?.tags, ["HOT_SHOWER", "SAUNA"])
        XCTAssertEqual(card?.state, .proposed)
        XCTAssertEqual(card?.text, "Save a note (hot shower, sauna)? Tap Confirm to log it.")
        XCTAssertEqual(EventProposalRules.tagLabel("HOT_SHOWER"), "Hot shower")
        XCTAssertFalse(vm.items.contains { $0.kind == .assistant(text: "") }, "no empty reply bubble is left behind")
    }

    // MARK: - Confirm / No

    func testConfirmCallsBackendOnceAndMarksConfirmed() async {
        let fake = FakeService()
        let vm = await streamedProposal(fake)
        fake.confirmResult = .success(confirmed())
        fake.confirmYields = true
        var notesChanged = 0
        vm.onNotesChanged = { notesChanged += 1 }

        async let first: Void = vm.confirmProposal(messageId: "p1")
        async let second: Void = vm.confirmProposal(messageId: "p1") // double tap
        _ = await (first, second)

        XCTAssertEqual(fake.confirms.count, 1)
        XCTAssertEqual(fake.confirms.first?.messageId, "p1")
        XCTAssertEqual(fake.confirms.first?.clientTime, "2026-10-30T12:00:00")
        XCTAssertEqual(fake.confirms.first?.timezone, "Europe/Berlin")
        XCTAssertEqual(proposalCard(vm)?.state, .confirmed)
        XCTAssertEqual(notesChanged, 1)
        XCTAssertTrue(vm.busyProposalIds.isEmpty)
        await vm.confirmProposal(messageId: "p1") // a confirmed card never calls again
        XCTAssertEqual(fake.confirms.count, 1)
    }

    func testClockOffIsShownAsAnErrorAndTheProposalStays() async {
        let fake = FakeService()
        let vm = await streamedProposal(fake)
        fake.confirmResult = .failure(GlucoseMonitorAPI.APIError.httpStatus(
            400, #"{"message":"Your phone's clock is off: it says 12:05, the server 12:00."}"#))

        await vm.confirmProposal(messageId: "p1")

        XCTAssertEqual(proposalCard(vm)?.state, .proposed)
        guard case .error(let message) = vm.items.last?.kind else { return XCTFail("no error row") }
        XCTAssertTrue(message.contains("clock is off"))
        XCTAssertTrue(message.contains(MealPlanRules.clockHint))
    }

    func testConflictReadsTheStateFromHistory() async {
        let fake = FakeService()
        let vm = await streamedProposal(fake)
        fake.confirmResult = .failure(GlucoseMonitorAPI.APIError.httpStatus(409, #"{"message":"Not allowed in state CONFIRMED"}"#))
        fake.pages = [[historyRow(state: "CONFIRMED")]]

        await vm.confirmProposal(messageId: "p1")

        XCTAssertEqual(proposalCard(vm)?.state, .confirmed)
        XCTAssertFalse(vm.items.contains { if case .error = $0.kind { return true }; return false })
    }

    func testNoDismissesLocallyWithoutCallingTheBackend() async {
        let fake = FakeService()
        let vm = await streamedProposal(fake)

        vm.dismissProposal(messageId: "p1")

        XCTAssertEqual(proposalCard(vm)?.state, .dismissed)
        await vm.confirmProposal(messageId: "p1")
        XCTAssertTrue(fake.confirms.isEmpty)
    }

    // MARK: - History

    private func historyRow(state: String) -> BackendAPI.ChatMessageDTO {
        let json = """
        {"id":"p1","createdAt":"2026-10-30T11:00:00Z","role":"ASSISTANT",
         "text":"Save a note (hot shower)? Tap Confirm to log it.","intent":"event_proposal","hasPhoto":false,
         "noteIds":[],"payload":{"userMessageId":"u1","language":"en","state":"\(state)",
         "comment":"just had a hot shower","tags":["HOT_SHOWER"]}}
        """
        return try! GlucoseMonitorAPI.jsonDecoder().decode(BackendAPI.ChatMessageDTO.self, from: Data(json.utf8))
    }

    func testHistoryRowRendersTheProposalWithItsState() {
        let proposed = ChatViewModel.items(fromNewestFirst: [historyRow(state: "PROPOSED")])
        XCTAssertEqual(proposed.count, 1)
        guard case .eventProposal(let card) = proposed[0].kind else { return XCTFail("not a proposal") }
        XCTAssertEqual(card.state, .proposed)
        XCTAssertEqual(card.tags, ["HOT_SHOWER"])
        XCTAssertEqual(card.text, "Save a note (hot shower)? Tap Confirm to log it.")

        let done = ChatViewModel.items(fromNewestFirst: [historyRow(state: "CONFIRMED")])
        guard case .eventProposal(let confirmedCard) = done[0].kind else { return XCTFail("not a proposal") }
        XCTAssertEqual(confirmedCard.state, .confirmed)
    }
}
