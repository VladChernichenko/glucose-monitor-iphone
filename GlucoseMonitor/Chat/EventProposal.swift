import SwiftUI

// MARK: - Contract (backend Task 15: MealPrepFlow.proposeEvent, MealActionService.confirmEvent)

extension BackendAPI {

    /// Payload of an `event_proposal` history row: `PROPOSED -> CONFIRMED` (Confirm saves the note).
    struct EventProposalPayload: Decodable, Equatable {
        let state: String?
        let tags: [String]
        let comment: String?
        let noteId: String?

        private enum CodingKeys: String, CodingKey { case state, tags, comment, noteId }

        init(state: String?, tags: [String], comment: String?, noteId: String? = nil) {
            self.state = state; self.tags = tags; self.comment = comment; self.noteId = noteId
        }

        init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            state = try? c.decodeIfPresent(String.self, forKey: .state)
            tags = ((try? c.decodeIfPresent([String].self, forKey: .tags)) ?? nil) ?? []
            comment = try? c.decodeIfPresent(String.self, forKey: .comment)
            noteId = try? c.decodeIfPresent(String.self, forKey: .noteId)
        }
    }

    /// The Confirm response (the backend's ActionResult).
    struct EventConfirmResult: Decodable, Equatable {
        let messageId: String
        let state: String
        let noteId: String?
        let payload: EventProposalPayload?
    }

    /// The stream's `proposal` line: `{"type":"proposal","messageId":…,"tags":[…],"comment":…}`.
    struct ProposalEventBody: Decodable {
        let messageId: String
        let tags: [String]?
        let comment: String?
    }

    static func eventConfirmPath(messageId: String) -> String {
        let id = messageId.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? messageId
        return "/api/assistant/events/\(id)/confirm"
    }

    static func eventConfirmBody(clientTime: String, timezone: String) -> Data {
        (try? JSONSerialization.data(withJSONObject: ["clientTime": clientTime, "timezone": timezone])) ?? Data("{}".utf8)
    }

    static func postEventConfirm(messageId: String, clientTime: String, timezone: String) async throws -> EventConfirmResult {
        // A rejected Confirm (409 already confirmed, 400 clock off) must never sign the user out.
        try await performWithRefresh(signOutIfUnreachable: false) {
            var req = try authorizedRequest(path: eventConfirmPath(messageId: messageId), method: "POST")
            req.httpBody = eventConfirmBody(clientTime: clientTime, timezone: timezone)
            let (data, resp) = try await URLSession.shared.data(for: req)
            try checkStatus(resp, data: data)
            return try GlucoseMonitorAPI.jsonDecoder().decode(EventConfirmResult.self, from: data)
        }
    }
}

// MARK: - Card model and rules

/// A proposed event note in the chat. "No" is local only: the backend keeps the proposal PROPOSED.
struct EventProposalCard: Equatable {
    enum State: Equatable { case proposed, confirmed, dismissed }

    let messageId: String
    let tags: [String]
    let comment: String?
    let text: String
    var state: State

    init(messageId: String, tags: [String], comment: String?, text: String? = nil, state: State = .proposed) {
        self.messageId = messageId
        self.tags = tags
        self.comment = comment
        self.text = (text?.isEmpty == false ? text : nil) ?? EventProposalRules.text(tags: tags)
        self.state = state
    }

    /// From a history row; the stored reply text is the one the backend wrote.
    init(messageId: String, payload: BackendAPI.EventProposalPayload, text: String?) {
        self.init(messageId: messageId, tags: payload.tags, comment: payload.comment, text: text,
                  state: EventProposalRules.state(payload.state))
    }
}

enum EventProposalRules {
    /// "HOT_SHOWER" -> "hot shower".
    static func tagName(_ tag: String) -> String { tag.lowercased().replacingOccurrences(of: "_", with: " ") }

    /// "HOT_SHOWER" -> "Hot shower" (chip label).
    static func tagLabel(_ tag: String) -> String {
        let name = tagName(tag)
        return name.prefix(1).uppercased() + name.dropFirst()
    }

    /// The stream sends no text for a proposal; this mirrors the reply the backend stores.
    static func text(tags: [String]) -> String {
        "Save a note (\(tags.map(tagName).joined(separator: ", ")))? Tap Confirm to log it."
    }

    static func state(_ raw: String?) -> EventProposalCard.State {
        raw == "CONFIRMED" ? .confirmed : .proposed
    }
}

// MARK: - View

struct EventProposalActions {
    let isBusy: Bool
    let onConfirm: () -> Void
    let onDismiss: () -> Void
}

/// Assistant bubble for a proposed event: text, tag chips, Confirm / No (or the final state).
struct EventProposalBubble: View {
    let card: EventProposalCard
    let actions: EventProposalActions

    var body: some View {
        HStack {
            VStack(alignment: .leading, spacing: 8) {
                Text(card.text).textSelection(.enabled)
                if !card.tags.isEmpty {
                    HStack(spacing: 6) {
                        ForEach(card.tags, id: \.self) { tag in
                            Text(EventProposalRules.tagLabel(tag))
                                .font(.caption)
                                .padding(.horizontal, 8)
                                .padding(.vertical, 3)
                                .background(Color.accentColor.opacity(0.15), in: Capsule())
                        }
                    }
                }
                switch card.state {
                case .proposed:
                    HStack(spacing: 8) {
                        Button("Confirm", action: actions.onConfirm)
                            .buttonStyle(.borderedProminent)
                        Button("No", action: actions.onDismiss)
                            .buttonStyle(.bordered)
                    }
                    .disabled(actions.isBusy)
                case .confirmed:
                    Label("Saved", systemImage: "checkmark.circle").font(.footnote).foregroundStyle(.secondary)
                case .dismissed:
                    Label("Not saved", systemImage: "xmark.circle").font(.footnote).foregroundStyle(.secondary)
                }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .background(Color(.secondarySystemBackground), in: RoundedRectangle(cornerRadius: 16))
            Spacer(minLength: 48)
        }
    }
}
