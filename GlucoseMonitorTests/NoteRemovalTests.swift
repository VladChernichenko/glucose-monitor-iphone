import XCTest
@testable import GlucoseMonitor

/// "Remove the 1 U" in chat: the `removal` stream event, Remove (deletes once), Keep (local only),
/// a conflict, and `removal_proposal` history rows.
@MainActor
final class NoteRemovalTests: XCTestCase {

    final class FakeService: AssistantChatService {
        var scriptedEvents: [BackendAPI.AssistantEvent] = []
        var pages: [[BackendAPI.ChatMessageDTO]] = []
        var removalResult: Result<BackendAPI.NoteRemovalResult, Error> = .failure(URLError(.badServerResponse))
        var removalYields = false
        private(set) var removals: [String] = []

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
                          timezone: String) async throws -> BackendAPI.EventConfirmResult { throw URLError(.badURL) }
        func confirmRemoval(messageId: String) async throws -> BackendAPI.NoteRemovalResult {
            removals.append(messageId)
            if removalYields { try? await Task.sleep(nanoseconds: 50_000_000) }
            return try removalResult.get()
        }
    }

    private func makeVM(_ fake: FakeService) -> ChatViewModel {
        ChatViewModel(service: fake, pageSize: 50, now: { Date(timeIntervalSince1970: 1_793_500_000) },
                      timeZone: TimeZone(identifier: "Europe/Berlin")!)
    }

    private func card(_ vm: ChatViewModel, _ id: String = "r1") -> NoteRemovalCard? {
        for item in vm.items where item.id == id {
            if case .noteRemoval(let card) = item.kind { return card }
        }
        return nil
    }

    private func streamed(_ fake: FakeService) async -> ChatViewModel {
        fake.scriptedEvents = [
            .removal(NoteRemovalCard(messageId: "r1", at: "01:56", insulin: 1, carbs: nil, label: "insulin")),
            .done(BackendAPI.AssistantDone(userMessageId: "u1", assistantMessageId: "r1", intent: "removal_proposal"))]
        let vm = makeVM(fake)
        _ = await vm.send(text: "Remove 1u. It was for testing purposes", photoJPEG: nil)
        return vm
    }

    func testDecodesTheRemovalStreamLine() {
        let line = #"{"type":"removal","messageId":"r1","noteId":"n1","at":"01:56","insulin":1.0,"label":"insulin"}"#
        guard case .removal(let c)? = BackendAPI.decodeAssistantEvent(line: line) else {
            return XCTFail("removal line not decoded")
        }
        XCTAssertEqual(c.summary, "01:56 · 1 U · insulin")
        XCTAssertEqual(c.state, .proposed)
    }

    func testStreamedRemovalShowsACardAndDeletesNothingUntilRemove() async {
        let fake = FakeService()
        let vm = await streamed(fake)

        XCTAssertEqual(card(vm)?.state, .proposed)
        XCTAssertEqual(card(vm)?.text, "Remove this entry: 01:56 · 1 U · insulin?")
        XCTAssertTrue(fake.removals.isEmpty)
    }

    func testRemoveDeletesOnceAndReloadsNotes() async {
        let fake = FakeService()
        fake.removalResult = .success(.init(messageId: "r1", state: "REMOVED", noteId: "n1", removed: true))
        fake.removalYields = true
        let vm = await streamed(fake)
        var notesChanged = 0
        vm.onNotesChanged = { notesChanged += 1 }

        async let first: Void = vm.confirmRemoval(messageId: "r1")
        async let second: Void = vm.confirmRemoval(messageId: "r1")
        _ = await (first, second)

        XCTAssertEqual(fake.removals, ["r1"])
        XCTAssertEqual(card(vm)?.state, .removed)
        XCTAssertEqual(notesChanged, 1)
    }

    func testKeepIsLocalOnly() async {
        let fake = FakeService()
        let vm = await streamed(fake)

        vm.keepRemoval(messageId: "r1")

        XCTAssertEqual(card(vm)?.state, .kept)
        XCTAssertTrue(fake.removals.isEmpty)
    }

    func testAQuickLogDoseIsReportedForTheInjectionSiteQuestion() async {
        let fake = FakeService()
        fake.scriptedEvents = [
            .logged(BackendAPI.AssistantLogged(noteIds: ["n7"], summary: "Logged 2 U.", iob: 2, forecastMin: 6.1)),
            .done(BackendAPI.AssistantDone(userMessageId: "u7", assistantMessageId: "a7", intent: "quick_log"))]
        let vm = makeVM(fake)
        var reported: [[String]] = []
        var plainRefreshes = 0
        vm.onDoseLogged = { reported.append($0) }
        vm.onNotesChanged = { plainRefreshes += 1 }

        _ = await vm.send(text: "2u", photoJPEG: nil)

        XCTAssertEqual(reported, [["n7"]])
        XCTAssertEqual(plainRefreshes, 0)
    }

    func testAnUndoneLogIsNotThePeekLine() {
        let entry = ChatLoggedEntry(summary: "Logged 1 U. IOB 1 U, lowest 6.4 in the next 4 h.", forecastMin: 6.4,
                                    undoMessageId: "u1", undone: true)
        XCTAssertEqual(ChatItem(id: "l1", createdAt: Date(), kind: .logged(entry)).previewText, "")
        var live = entry
        live.undone = false
        XCTAssertEqual(ChatItem(id: "l1", createdAt: Date(), kind: .logged(live)).previewText, entry.summary)
    }

    func testHistoryRowBecomesARemovedCard() throws {
        let json = #"""
        [{"id":"r1","createdAt":"2026-11-01T00:58:00Z","role":"ASSISTANT","text":"Remove this entry: 01:56 · 1 U · insulin? Tap Remove.",
          "intent":"removal_proposal","hasPhoto":false,"noteIds":[],
          "payload":{"state":"REMOVED","noteId":"n1","at":"01:56","insulin":1.0,"label":"insulin"}}]
        """#
        let rows = try GlucoseMonitorAPI.jsonDecoder().decode([BackendAPI.ChatMessageDTO].self, from: Data(json.utf8))
        let items = ChatViewModel.items(fromNewestFirst: rows)

        guard case .noteRemoval(let c) = items.first?.kind else { return XCTFail("not a removal card") }
        XCTAssertEqual(c.state, .removed)
        XCTAssertEqual(c.insulin, 1)
    }
}
