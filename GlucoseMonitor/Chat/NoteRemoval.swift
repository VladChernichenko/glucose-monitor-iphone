import SwiftUI

// MARK: - Contract (backend NoteRemovalFlow: "remove the 1 U" -> removal card -> Remove deletes the note)

extension BackendAPI {

    /// Payload of a `removal_proposal` history row: `PROPOSED -> REMOVED` (Remove deletes the note).
    struct NoteRemovalPayload: Decodable, Equatable {
        let state: String?
        let noteId: String?
        let at: String?
        let insulin: Double?
        let carbs: Double?
        let label: String?
    }

    /// The Remove response (the backend's NoteRemovalFlow.Result); `removed` is false when the note was already gone.
    struct NoteRemovalResult: Decodable, Equatable {
        let messageId: String
        let state: String
        let noteId: String?
        let removed: Bool
    }

    /// The stream's `removal` line.
    struct RemovalEventBody: Decodable {
        let messageId: String
        let noteId: String?
        let at: String?
        let insulin: Double?
        let carbs: Double?
        let label: String?
    }

    static func removalConfirmPath(messageId: String) -> String {
        let id = messageId.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? messageId
        return "/api/assistant/removals/\(id)/confirm"
    }

    static func postRemovalConfirm(messageId: String) async throws -> NoteRemovalResult {
        // A rejected Remove (409 already removed) must never sign the user out.
        try await performWithRefresh(signOutIfUnreachable: false) {
            let req = try authorizedRequest(path: removalConfirmPath(messageId: messageId), method: "POST")
            let (data, resp) = try await URLSession.shared.data(for: req)
            try checkStatus(resp, data: data)
            return try GlucoseMonitorAPI.jsonDecoder().decode(NoteRemovalResult.self, from: data)
        }
    }
}

// MARK: - Card model and rules

/// A logged note proposed for removal in the chat. "Keep" is local only: the backend keeps it PROPOSED.
struct NoteRemovalCard: Equatable {
    enum State: Equatable { case proposed, removed, kept }

    let messageId: String
    let at: String?
    let insulin: Double?
    let carbs: Double?
    let label: String?
    var state: State

    init(messageId: String, at: String?, insulin: Double?, carbs: Double?, label: String?, state: State = .proposed) {
        self.messageId = messageId
        self.at = at
        self.insulin = insulin
        self.carbs = carbs
        self.label = label
        self.state = state
    }

    init(messageId: String, payload: BackendAPI.NoteRemovalPayload) {
        self.init(messageId: messageId, at: payload.at, insulin: payload.insulin, carbs: payload.carbs,
                  label: payload.label, state: payload.state == "REMOVED" ? .removed : .proposed)
    }

    /// "01:56 · 1 U · insulin"
    var summary: String {
        var parts: [String] = []
        if let at { parts.append(at) }
        if let insulin { parts.append("\(ChatFormatting.backendNumber(insulin)) U") }
        if let carbs { parts.append("\(ChatFormatting.backendNumber(carbs)) g") }
        if let label { parts.append(label) }
        return parts.joined(separator: " · ")
    }

    var text: String { "Remove this entry: \(summary)?" }
}

// MARK: - View

struct NoteRemovalActions {
    let isBusy: Bool
    let onRemove: () -> Void
    let onKeep: () -> Void
}

/// Assistant bubble for a proposed removal: the entry, Remove / Keep (or the final state).
struct NoteRemovalBubble: View {
    let card: NoteRemovalCard
    let actions: NoteRemovalActions

    var body: some View {
        HStack {
            VStack(alignment: .leading, spacing: 8) {
                Text(card.text).textSelection(.enabled)
                switch card.state {
                case .proposed:
                    HStack(spacing: 8) {
                        Button("Remove", role: .destructive, action: actions.onRemove)
                            .buttonStyle(.borderedProminent)
                        Button("Keep", action: actions.onKeep)
                            .buttonStyle(.bordered)
                    }
                    .disabled(actions.isBusy)
                case .removed:
                    Label("Removed", systemImage: "trash").font(.footnote).foregroundStyle(.secondary)
                case .kept:
                    Label("Kept", systemImage: "xmark.circle").font(.footnote).foregroundStyle(.secondary)
                }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .background(Color(.secondarySystemBackground), in: RoundedRectangle(cornerRadius: 16))
            Spacer(minLength: 48)
        }
    }
}
