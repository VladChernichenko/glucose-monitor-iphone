import Foundation
import UIKit

/// State of the dashboard chat: history paging, streaming a reply, quick-log Undo.
@MainActor
final class ChatViewModel: ObservableObject {
    @Published private(set) var items: [ChatItem] = []
    /// Id of the message that was on top before an older page was prepended; the view scrolls back to it.
    @Published private(set) var scrollAnchorId: String?
    @Published private(set) var isSending = false
    @Published private(set) var isLoadingOlder = false
    @Published private(set) var hasMoreHistory = true
    @Published private(set) var historyLoaded = false
    @Published private(set) var hitRate: BackendAPI.AssistantHitRate?
    /// Plan cards with an action in flight; their buttons are disabled (double-tap protection).
    @Published private(set) var busyPlanIds: Set<String> = []
    /// Per plan card: where the user is on the history banner (nothing preselected).
    @Published private(set) var bannerStates: [String: HistoryBannerState] = [:]
    /// Event proposals with a Confirm in flight; their buttons are disabled (double-tap protection).
    @Published private(set) var busyProposalIds: Set<String> = []
    /// Removal cards with a Remove in flight; their buttons are disabled (double-tap protection).
    @Published private(set) var busyRemovalIds: Set<String> = []

    /// Called after a quick log is written or undone, so the dashboard reloads notes, IOB and COB.
    var onNotesChanged: (() -> Void)?

    private let service: AssistantChatService
    private let pageSize: Int
    private let now: () -> Date
    private let timeZone: TimeZone

    init(service: AssistantChatService = BackendAssistantService(), pageSize: Int = 50,
         now: @escaping () -> Date = Date.init, timeZone: TimeZone = .current) {
        self.service = service
        self.pageSize = pageSize
        self.now = now
        self.timeZone = timeZone
    }

    /// The glycemic question awaiting an answer; rendered as the last bubble regardless of new messages.
    @Published private(set) var pendingPrompt: BackendAPI.GlycemicEvent?
    private var pendingPromptText = ""

    /// Answers the prompt (AppState confirm); returns false when saving failed and the prompt must stay.
    var onAnswerPrompt: ((_ event: BackendAPI.GlycemicEvent, _ category: String, _ carbs: Double?, _ insulin: Double?) async -> Bool)?
    /// "Nothing": dismisses the event; returns false on failure.
    var onDismissPrompt: ((_ event: BackendAPI.GlycemicEvent) async -> Bool)?
    /// "Not sure": hides the question on this device only.
    var onSnoozePrompt: (() -> Void)?

    /// History plus the pinned prompt bubble, in display order.
    var bubbles: [ChatItem] {
        guard let event = pendingPrompt else { return items }
        return items + [ChatItem(id: "prompt-\(event.id)", createdAt: event.windowEnd,
                                 kind: .glycemicPrompt(event, text: pendingPromptText))]
    }

    var lastMessageLine: String? {
        bubbles.last(where: { !$0.previewText.isEmpty })?.previewText
    }

    // MARK: Glycemic prompt

    func setPendingPrompt(_ event: BackendAPI.GlycemicEvent?, displayUnit: String) {
        pendingPrompt = event
        pendingPromptText = event.map { ChatFormatting.promptText($0, unit: displayUnit) } ?? ""
    }

    func answerPrompt(category: String, carbs: Double?, insulin: Double?) async {
        guard let event = pendingPrompt, let handler = onAnswerPrompt else { return }
        guard await handler(event, category, carbs, insulin) else { return }
        clearPrompt(event)
        appendAssistant(ChatFormatting.promptConfirmation(category: category, carbs: carbs, insulin: insulin))
    }

    func dismissPrompt() async {
        guard let event = pendingPrompt, let handler = onDismissPrompt else { return }
        guard await handler(event) else { return }
        clearPrompt(event)
        appendAssistant("OK, nothing to log.")
    }

    func snoozePrompt() {
        onSnoozePrompt?()
        pendingPrompt = nil
        pendingPromptText = ""
    }

    private func clearPrompt(_ event: BackendAPI.GlycemicEvent) {
        if pendingPrompt?.id == event.id { pendingPrompt = nil; pendingPromptText = "" }
    }

    private func appendAssistant(_ text: String) {
        items.append(ChatItem(id: "local-\(UUID().uuidString)", createdAt: now(), kind: .assistant(text: text)))
    }

    // MARK: Hit rate

    /// "Twin 74%"; nil (pill hidden) until at least one forecast has been checked.
    var hitRateLabel: String? {
        guard let percent = hitRate?.percent else { return nil }
        return "Twin \(Int(percent.rounded()))%"
    }

    func loadHitRate() async {
        do {
            hitRate = try await service.fetchHitRate()
        } catch {
            // Keep the last value (or no pill); the next appearance retries.
        }
    }

    // MARK: History

    func loadInitial() async {
        await loadHitRate()
        guard !historyLoaded else { return }
        do {
            let page = try await service.fetchHistory(before: nil, limit: pageSize)
            let fresh = Self.items(fromNewestFirst: page).filter { item in !items.contains { $0.id == item.id } }
            items = fresh + items
            hasMoreHistory = page.count >= pageSize
            historyLoaded = true
        } catch {
            // Leave history empty; the input still works and the next appearance retries.
        }
    }

    func loadOlder() async {
        guard historyLoaded, hasMoreHistory, !isLoadingOlder, let oldest = items.first else { return }
        isLoadingOlder = true
        defer { isLoadingOlder = false }
        do {
            let page = try await service.fetchHistory(before: oldest.createdAt, limit: pageSize)
            let known = Set(items.map(\.id))
            let older = Self.items(fromNewestFirst: page).filter { !known.contains($0.id) }
            hasMoreHistory = page.count >= pageSize
            guard !older.isEmpty else { return }
            scrollAnchorId = oldest.id
            items = older + items
        } catch {
            // Keep what is shown; scrolling to the top again retries.
        }
    }

    /// Maps a newest-first history page to oldest-first items. A quick-log reply reads its Undo state
    /// from the USER row it belongs to (`payload.undone`). A meal plan row becomes its card followed by
    /// the explanation text.
    static func items(fromNewestFirst rows: [BackendAPI.ChatMessageDTO]) -> [ChatItem] {
        let undoneUserIds = Set(rows.filter { $0.role == "USER" && $0.payload?.undone == true }.map(\.id))
        return rows.reversed().flatMap { row -> [ChatItem] in
            if row.role != "USER", let payload = row.eventProposal {
                let card = EventProposalCard(messageId: row.id, payload: payload, text: row.text)
                return [ChatItem(id: row.id, createdAt: row.createdAt, kind: .eventProposal(card))]
            }
            if row.role != "USER", let payload = row.noteRemoval {
                let card = NoteRemovalCard(messageId: row.id, payload: payload)
                return [ChatItem(id: row.id, createdAt: row.createdAt, kind: .noteRemoval(card))]
            }
            if let payload = row.mealPlan, let card = MealPlanCard(messageId: row.id, payload: payload) {
                var out = [ChatItem(id: row.id, createdAt: row.createdAt, kind: .mealPlan(card))]
                if let text = row.text, !text.isEmpty {
                    out.append(ChatItem(id: row.id + "-text", createdAt: row.createdAt, kind: .assistant(text: text)))
                }
                return out
            }
            var out = [item(from: row, undoneUserIds: undoneUserIds)]
            if row.role != "USER", let citations = row.payload?.citations, !citations.isEmpty {
                out.append(ChatItem(id: "citations-\(row.id)", createdAt: row.createdAt, kind: .citations(citations)))
            }
            if row.role != "USER", let episodes = row.payload?.episodes, !episodes.isEmpty {
                out.insert(ChatItem(id: "episodes-\(row.id)", createdAt: row.createdAt, kind: .episodes(episodes)), at: 0)
            }
            return out
        }
    }

    private static func item(from row: BackendAPI.ChatMessageDTO, undoneUserIds: Set<String>) -> ChatItem {
        if row.role == "USER" {
            return ChatItem(id: row.id, createdAt: row.createdAt,
                            kind: .user(text: row.text ?? "", hasPhoto: row.hasPhoto))
        }
        if let p = row.payload, p.type == "logged" {
            let userId = p.userMessageId ?? row.id
            let entry = ChatLoggedEntry(summary: p.summary ?? row.text ?? "", forecastMin: p.forecastMin,
                                        undoMessageId: userId,
                                        undone: undoneUserIds.contains(userId) || p.undone == true)
            return ChatItem(id: row.id, createdAt: row.createdAt, kind: .logged(entry))
        }
        return ChatItem(id: row.id, createdAt: row.createdAt, kind: .assistant(text: row.text ?? ""),
                        isFailed: row.intent == "question_failed")
    }

    // MARK: Sending

    func send(text: String, photo: UIImage?) async {
        await send(text: text, photoJPEG: photo.flatMap(BackendAPI.assistantPhotoJPEG))
    }

    @discardableResult
    func send(text: String, photoJPEG: Data?) async -> Bool {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !isSending, !trimmed.isEmpty || photoJPEG != nil else { return false }
        sendFailed = false
        isSending = true
        defer { isSending = false }

        let sentAt = now()
        items.append(ChatItem(id: "local-\(UUID().uuidString)", createdAt: sentAt,
                              kind: .user(text: trimmed, hasPhoto: photoJPEG != nil)))
        let replyId = "local-\(UUID().uuidString)"
        items.append(ChatItem(id: replyId, createdAt: sentAt, kind: .assistant(text: "")))

        do {
            try await service.sendMessage(text: trimmed.isEmpty ? nil : trimmed, photoJPEG: photoJPEG,
                                          clientTime: BackendAPI.assistantClientTime(sentAt, timeZone: timeZone),
                                          timezone: timeZone.identifier) { [weak self] event in
                self?.apply(event, to: replyId)
            }
        } catch {
            // A 4xx carries the server's reason (e.g. the phone clock is off); show it as-is.
            appendError(MealPlanRules.serverRejection(error)
                        ?? "Couldn't reach the assistant. \(error.localizedDescription)", replacing: replyId)
        }
        // A reply that never got text (e.g. the stream ended early) leaves no empty bubble behind.
        if let i = index(of: replyId), items[i].kind == .assistant(text: "") { items.remove(at: i) }
        // The stream's plan has no items; the stored payload does (Edit needs them).
        if let planId = streamedPlanId { streamedPlanId = nil; await refreshPlan(messageId: planId) }
        await loadHitRate() // a quick log can add a frozen snapshot
        return !sendFailed
    }

    private func attachBanner(messageId: String, _ banner: BackendAPI.HistoryBanner) {
        guard let i = index(of: messageId), case .mealPlan(var card) = items[i].kind else { return }
        card.payload.banner = banner
        items[i].kind = .mealPlan(card)
    }

    private var sendFailed = false
    private var streamedPlanId: String?

    /// "Took N g" on the carb advice card: logs fast sugar through the normal chat send path,
    /// where the backend quick-log parser attaches it to an open low.
    /// Returns true when the message was delivered without an error.
    @discardableResult
    func sendFastCarbs(grams: Int) async -> Bool {
        await send(text: "\(grams)g fast", photoJPEG: nil)
    }

    private func apply(_ event: BackendAPI.AssistantEvent, to replyId: String) {
        guard let i = index(of: replyId) else { return }
        switch event {
        case .token(let piece):
            if case .assistant(let text) = items[i].kind { items[i].kind = .assistant(text: text + piece) }
        case .logged(let logged):
            items[i].kind = .logged(ChatLoggedEntry(summary: logged.summary, forecastMin: logged.forecastMin,
                                                    undoMessageId: nil, undone: false))
            onNotesChanged?()
        case .done(let done):
            if case .logged(var entry) = items[i].kind {
                entry.undoMessageId = done.userMessageId ?? done.assistantMessageId
                items[i].kind = .logged(entry)
            }
        case .error(let message):
            appendError(message, replacing: replyId)
        case .plan(let messageId, let plan, let plannedAt, let doseValidUntil):
            // The card goes above the reply bubble, which keeps streaming the explanation.
            let card = MealPlanCard(messageId: messageId, plan: plan, plannedAt: plannedAt,
                                    doseValidUntil: doseValidUntil)
            items.insert(ChatItem(id: messageId, createdAt: items[i].createdAt, kind: .mealPlan(card)), at: i)
            streamedPlanId = messageId
        case .episodes(let episodes):
            // Above the reply bubble (under a plan card, which was inserted earlier).
            guard !episodes.isEmpty else { break }
            items.insert(ChatItem(id: "episodes-\(replyId)", createdAt: items[i].createdAt, kind: .episodes(episodes)), at: i)
        case .banner(let messageId, let banner):
            attachBanner(messageId: messageId, banner)
        case .citations(let citations):
            // Under the reply bubble it belongs to (the event arrives before the first token).
            guard !citations.isEmpty else { break }
            items.insert(ChatItem(id: "citations-\(replyId)", createdAt: items[i].createdAt, kind: .citations(citations)), at: i + 1)
        case .proposal(let messageId, let tags, let comment):
            // No tokens follow a proposal: the bubble (with Confirm / No) takes the reply's place.
            let card = EventProposalCard(messageId: messageId, tags: tags, comment: comment)
            items[i] = ChatItem(id: messageId, createdAt: items[i].createdAt, kind: .eventProposal(card))
        case .removal(let card):
            // No tokens follow a removal proposal: the bubble (with Remove / Keep) takes the reply's place.
            items[i] = ChatItem(id: card.messageId, createdAt: items[i].createdAt, kind: .noteRemoval(card))
        }
    }

    /// Turns an empty reply placeholder into the error row, or appends one after partial text.
    private func appendError(_ message: String, replacing replyId: String) {
        sendFailed = true
        if let i = index(of: replyId), items[i].kind == .assistant(text: "") {
            items[i].kind = .error(message)
        } else {
            items.append(ChatItem(id: "local-\(UUID().uuidString)", createdAt: now(), kind: .error(message)))
        }
    }

    // MARK: Undo

    func undo(itemId: String) async {
        guard let i = index(of: itemId), case .logged(let entry) = items[i].kind,
              !entry.undone, let messageId = entry.undoMessageId else { return }
        do {
            _ = try await service.undo(messageId: messageId)
            // `undone:false` means it was already undone elsewhere; either way the notes are gone.
            if let j = index(of: itemId), case .logged(var current) = items[j].kind {
                current.undone = true
                items[j].kind = .logged(current)
            }
            onNotesChanged?()
        } catch {
            items.append(ChatItem(id: "local-\(UUID().uuidString)", createdAt: now(),
                                  kind: .error("Undo failed. \(error.localizedDescription)")))
        }
    }

    // MARK: Meal plan actions

    func tookPlan(messageId: String, doseUnits: Double, pauseMinutes: Int) async {
        await runPlanAction(messageId: messageId, .took(doseUnits: doseUnits, pauseMinutes: pauseMinutes))
    }

    /// Eating now (TOOK) or eating without insulin (PLANNED); nil macros (or nil fields) use the
    /// planned meal. `ateAt` dates a late meal; nil = now.
    func eatPlan(messageId: String, macros: BackendAPI.MealMacros?, ateAt: Date?) async {
        let at = ateAt.map { BackendAPI.assistantClientTime($0, timeZone: timeZone) }
        await runPlanAction(messageId: messageId, .eating(macros ?? BackendAPI.MealMacros(), ateAt: at))
    }

    /// The newest plan card in the chat. A PLANNED card is actionable only if it is this one: the backend
    /// supersedes every older PLANNED plan when it makes a new one, whatever happens to the new one later.
    var newestPlanId: String? {
        for item in items.reversed() {
            if case .mealPlan(let card) = item.kind { return card.messageId }
        }
        return nil
    }

    func skipPlan(messageId: String) async {
        await runPlanAction(messageId: messageId, .skip)
    }

    /// Edit: there is no re-plan endpoint, so the edited items go out as a new meal-prep message.
    func replan(items: [BackendAPI.MealPlanItem]) async {
        await send(text: MealPlanRules.replanMessage(items), photoJPEG: nil)
    }

    // MARK: Event proposals

    /// Confirm: saves the note once (a second tap while in flight, or on a confirmed card, does nothing).
    func confirmProposal(messageId: String) async {
        guard !busyProposalIds.contains(messageId), proposal(messageId)?.state == .proposed else { return }
        busyProposalIds.insert(messageId)
        defer { busyProposalIds.remove(messageId) }
        do {
            let result = try await service.confirmEvent(
                messageId: messageId, clientTime: BackendAPI.assistantClientTime(now(), timeZone: timeZone),
                timezone: timeZone.identifier)
            setProposalState(messageId, EventProposalRules.state(result.payload?.state ?? result.state))
            if result.noteId != nil { onNotesChanged?() }
        } catch {
            switch MealPlanRules.classify(error) {
            case .conflict:
                // Already confirmed elsewhere (or a second device): show the stored state, not an error.
                await refreshProposal(messageId: messageId)
            case .rejected(let message), .failed(let message):
                items.append(ChatItem(id: "local-\(UUID().uuidString)", createdAt: now(), kind: .error(message)))
            }
        }
    }

    /// "No": nothing is saved; the backend keeps the proposal, so it shows again after a reload.
    func dismissProposal(messageId: String) {
        guard !busyProposalIds.contains(messageId), proposal(messageId)?.state == .proposed else { return }
        setProposalState(messageId, .dismissed)
    }

    private func refreshProposal(messageId: String) async {
        guard let i = index(of: messageId) else { return }
        for before in [nil, items[i].createdAt.addingTimeInterval(60)] as [Date?] {
            guard let page = try? await service.fetchHistory(before: before, limit: pageSize) else { continue }
            if let payload = page.first(where: { $0.id == messageId })?.eventProposal {
                setProposalState(messageId, EventProposalRules.state(payload.state))
                return
            }
        }
    }

    private func proposal(_ messageId: String) -> EventProposalCard? {
        guard let i = index(of: messageId), case .eventProposal(let card) = items[i].kind else { return nil }
        return card
    }

    private func setProposalState(_ messageId: String, _ state: EventProposalCard.State) {
        guard let i = index(of: messageId), case .eventProposal(var card) = items[i].kind else { return }
        card.state = state
        items[i].kind = .eventProposal(card)
    }

    // MARK: Note removal

    /// Remove: deletes the note once (a second tap while in flight, or on a removed card, does nothing).
    func confirmRemoval(messageId: String) async {
        guard !busyRemovalIds.contains(messageId), removal(messageId)?.state == .proposed else { return }
        busyRemovalIds.insert(messageId)
        defer { busyRemovalIds.remove(messageId) }
        do {
            _ = try await service.confirmRemoval(messageId: messageId)
            setRemovalState(messageId, .removed)
            onNotesChanged?()
            await refreshLoggedUndoState()
        } catch {
            switch MealPlanRules.classify(error) {
            case .conflict:
                // Already removed (another device, or a reload raced the tap): the note is gone either way.
                setRemovalState(messageId, .removed)
                onNotesChanged?()
            case .rejected(let message), .failed(let message):
                items.append(ChatItem(id: "local-\(UUID().uuidString)", createdAt: now(), kind: .error(message)))
            }
        }
    }

    /// "Keep": nothing is deleted; the backend keeps the proposal, so it shows again after a reload.
    func keepRemoval(messageId: String) {
        guard !busyRemovalIds.contains(messageId), removal(messageId)?.state == .proposed else { return }
        setRemovalState(messageId, .kept)
    }

    /// The backend marks the quick log that wrote a removed note undone; re-read the newest page so that
    /// log's Undo turns off (matched by its undo message id: streamed rows carry local ids).
    private func refreshLoggedUndoState() async {
        guard let page = try? await service.fetchHistory(before: nil, limit: pageSize) else { return }
        let undoneIds = Set(Self.items(fromNewestFirst: page).compactMap { item -> String? in
            guard case .logged(let entry) = item.kind, entry.undone else { return nil }
            return entry.undoMessageId
        })
        for i in items.indices {
            guard case .logged(var entry) = items[i].kind, !entry.undone,
                  let id = entry.undoMessageId, undoneIds.contains(id) else { continue }
            entry.undone = true
            items[i].kind = .logged(entry)
        }
    }

    private func removal(_ messageId: String) -> NoteRemovalCard? {
        guard let i = index(of: messageId), case .noteRemoval(let card) = items[i].kind else { return nil }
        return card
    }

    private func setRemovalState(_ messageId: String, _ state: NoteRemovalCard.State) {
        guard let i = index(of: messageId), case .noteRemoval(var card) = items[i].kind else { return }
        card.state = state
        items[i].kind = .noteRemoval(card)
    }

    // MARK: History banner

    func bannerState(_ messageId: String) -> HistoryBannerState { bannerStates[messageId] ?? .initial }

    /// Use N U / Keep N U: re-checks the chosen dose for lows. OK and AMBER adopt it; RED waits for
    /// `confirmBannerRed`; a refusal or failure keeps the dose unknown.
    func chooseBannerDose(messageId: String, units: Double) async {
        guard let i = index(of: messageId), case .mealPlan(let card) = items[i].kind, card.payload.banner != nil else { return }
        if case .checking = bannerState(messageId) { return }
        bannerStates[messageId] = .checking(units: units)
        do {
            let result = try await service.recheckDose(
                messageId: messageId, doseUnits: units,
                clientTime: BackendAPI.assistantClientTime(now(), timeZone: timeZone), timezone: timeZone.identifier)
            bannerStates[messageId] = HistoryBannerRules.state(units: units, recheck: result)
        } catch {
            switch MealPlanRules.classify(error) {
            case .conflict:
                bannerStates[messageId] = .initial
                await refreshPlan(messageId: messageId)
            case .rejected(let message), .failed(let message):
                bannerStates[messageId] = .unanswered(notice: message)
            }
        }
    }

    /// The second, explicit tap on a RED answer ("Use N U anyway").
    func confirmBannerRed(messageId: String) {
        bannerStates[messageId] = HistoryBannerRules.confirmRed(bannerState(messageId))
    }

    /// "Back": drop the answer; nothing is selected again.
    func resetBanner(messageId: String) {
        if case .checking = bannerState(messageId) { return }
        bannerStates[messageId] = .initial
    }

    private func runPlanAction(messageId: String, _ action: BackendAPI.MealPlanAction) async {
        guard !busyPlanIds.contains(messageId) else { return }
        busyPlanIds.insert(messageId)
        defer { busyPlanIds.remove(messageId) }
        let at = now()
        do {
            let result = try await service.mealPlanAction(
                messageId: messageId, action: action,
                clientTime: BackendAPI.assistantClientTime(at, timeZone: timeZone), timezone: timeZone.identifier)
            setPlanPayload(messageId: messageId, result.payload)
            if result.noteId != nil { onNotesChanged?() }
        } catch {
            switch MealPlanRules.classify(error) {
            case .conflict:
                // Already done elsewhere (or a second tap): show the real state, not an error.
                await refreshPlan(messageId: messageId)
            case .rejected(let message), .failed(let message):
                items.append(ChatItem(id: "local-\(UUID().uuidString)", createdAt: now(), kind: .error(message)))
            }
        }
    }

    /// Re-reads one plan message from history (newest page, then the page around it).
    func refreshPlan(messageId: String) async {
        guard let i = index(of: messageId) else { return }
        let around = items[i].createdAt.addingTimeInterval(60)
        for before in [nil, around] as [Date?] {
            guard let page = try? await service.fetchHistory(before: before, limit: pageSize) else { continue }
            if let row = page.first(where: { $0.id == messageId }), let payload = row.mealPlan, payload.plan != nil {
                setPlanPayload(messageId: messageId, payload)
                return
            }
        }
    }

    private func setPlanPayload(messageId: String, _ payload: BackendAPI.MealPlanPayload) {
        guard let i = index(of: messageId), case .mealPlan(var card) = items[i].kind, payload.plan != nil else { return }
        card.payload = payload
        items[i].kind = .mealPlan(card)
    }

    private func index(of id: String) -> Int? { items.firstIndex { $0.id == id } }
}
