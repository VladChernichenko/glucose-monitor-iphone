import Foundation
import UIKit

/// A quick log shown in the chat, with its Undo state.
struct ChatLoggedEntry: Equatable {
    let summary: String
    let forecastMin: Double?
    /// Message id the undo endpoint takes; nil until the stream's `done` event names it.
    var undoMessageId: String?
    var undone: Bool
}

struct ChatItem: Identifiable, Equatable {
    enum Kind: Equatable {
        case user(text: String, hasPhoto: Bool)
        case assistant(text: String)
        case logged(ChatLoggedEntry)
        case error(String)
        /// The glycemic event engine's pending question, pinned last; `text` is the preview line.
        case glycemicPrompt(BackendAPI.GlycemicEvent, text: String)
    }

    let id: String
    let createdAt: Date
    var kind: Kind
    /// A reply the backend could not finish (history intent `question_failed`); shown muted.
    var isFailed = false

    /// One-line text for the dashboard peek.
    var previewText: String {
        switch kind {
        case .user(let text, let hasPhoto): return text.isEmpty && hasPhoto ? "Photo" : text
        case .assistant(let text): return text
        case .logged(let entry): return entry.summary
        case .error(let message): return message
        case .glycemicPrompt(_, let text): return text
        }
    }
}

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
    /// from the USER row it belongs to (`payload.undone`).
    static func items(fromNewestFirst rows: [BackendAPI.ChatMessageDTO]) -> [ChatItem] {
        let undoneUserIds = Set(rows.filter { $0.role == "USER" && $0.payload?.undone == true }.map(\.id))
        return rows.reversed().map { row in
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
    }

    // MARK: Sending

    func send(text: String, photo: UIImage?) async {
        await send(text: text, photoJPEG: photo.flatMap(BackendAPI.assistantPhotoJPEG))
    }

    func send(text: String, photoJPEG: Data?) async {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !isSending, !trimmed.isEmpty || photoJPEG != nil else { return }
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
            appendError("Couldn't reach the assistant. \(error.localizedDescription)", replacing: replyId)
        }
        // A reply that never got text (e.g. the stream ended early) leaves no empty bubble behind.
        if let i = index(of: replyId), items[i].kind == .assistant(text: "") { items.remove(at: i) }
        await loadHitRate() // a quick log can add a frozen snapshot
    }

    /// "Took N g" on the carb advice card: logs fast sugar through the normal chat send path,
    /// where the backend quick-log parser attaches it to an open low.
    func sendFastCarbs(grams: Int) async {
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
        case .banner, .plan, .episodes, .citations:
            break // Rendered by later tasks.
        }
    }

    /// Turns an empty reply placeholder into the error row, or appends one after partial text.
    private func appendError(_ message: String, replacing replyId: String) {
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

    private func index(of id: String) -> Int? { items.firstIndex { $0.id == id } }
}

/// Display formatting for the chat. The backend works in mmol/L; mg/dL users see mg/dL.
enum ChatFormatting {

    static func glucose(mmol: Double, unit: String) -> String {
        GlucoseUnit.isMgdl(unit)
            ? String(format: "%.0f", GlucoseUnit.mmolToMgdl(mmol))
            : String(format: "%.1f", mmol)
    }

    /// e.g. "Unexplained rise 14:10-14:55, +58 mg/dL above forecast. Anything to log?"
    static func promptText(_ event: BackendAPI.GlycemicEvent, unit: String) -> String {
        "\(event.displayLabel): \(GlycemicEventCopy.summary(for: event, displayUnit: unit)). \(GlycemicEventCopy.question(for: event))"
    }

    static func promptConfirmation(category: String, carbs: Double?, insulin: Double?) -> String {
        var text = "Noted: \(GlycemicCategory.buttonTitle(category))"
        if let carbs { text += ", \(backendNumber(carbs)) g" }
        if let insulin { text += ", \(backendNumber(insulin)) U" }
        return text + "."
    }

    static func iobCob(iob: Double?, cob: Double?) -> String {
        let i = iob.map { String(format: "%.1f U", $0) } ?? "--"
        let c = cob.map { String(format: "%.0f g", $0) } ?? "--"
        return "IOB \(i) · COB \(c)"
    }

    /// The backend writes the 4 h forecast low into `summary` in mmol/L ("lowest 5.8", "минимум 5.8").
    /// For mg/dL users that number is replaced with the mg/dL value; everything else is kept as sent.
    static func loggedSummary(_ summary: String, forecastMin: Double?, unit: String) -> String {
        guard let forecastMin, GlucoseUnit.isMgdl(unit) else { return summary }
        let sent = backendNumber(forecastMin)
        let shown = glucose(mmol: forecastMin, unit: unit)
        var result = summary
        for label in ["lowest ", "минимум "] {
            result = result.replacingOccurrences(of: label + sent, with: label + shown)
        }
        return result
    }

    /// Mirrors the backend's `AssistantService.fmt`: one decimal, whole numbers without ".0".
    static func backendNumber(_ v: Double) -> String {
        let r = (v * 10).rounded() / 10
        return r == r.rounded() ? String(Int(r)) : String(r)
    }
}
