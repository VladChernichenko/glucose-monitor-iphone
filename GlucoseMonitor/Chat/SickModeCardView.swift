import SwiftUI

/// A sick mode confirmation in the chat. The event only proposes; Turn on / End sick mode do the work.
struct SickModeChatCard: Equatable {
    enum Action: Equatable { case start, end }
    enum State: Equatable { case open, done(String) }

    let messageId: String
    let action: Action
    /// The level the user stated; preselected on a START card.
    let severity: SickSeverity?
    let current: SickModeStatus?
    var state: State = .open

    init?(messageId: UUID, action: String, severity: SickSeverity?, current: SickModeStatus?) {
        switch action {
        case "START": self.action = .start
        case "END": self.action = .end
        default: return nil
        }
        self.messageId = messageId.uuidString.lowercased()
        self.severity = severity
        self.current = current
    }

    static func doneOnText(_ severity: SickSeverity) -> String { "Sick mode is on · \(SickModeText.name(severity))" }
    static let doneEndedText = "Sick mode ended"
    static let notOnText = "Sick mode is not on."

    /// Sick mode is already on, so a START card has nothing to turn on (changing level is done on the dashboard).
    var alreadyOn: Bool { current?.active == true }
    /// An END card with sick mode known to be off.
    var alreadyOff: Bool { current.map { !$0.active } ?? false }

    var previewText: String {
        if case .done(let text) = state { return text }
        switch action {
        case .start: return alreadyOn ? SickModeText.title(current!) : "Turn on sick mode?"
        case .end: return alreadyOff ? Self.notOnText : "End sick mode?"
        }
    }
}

struct SickModeChatActions {
    let isBusy: Bool
    let onTurnOn: (_ severity: SickSeverity, _ since: SickSince) -> Void
    let onEnd: () -> Void
}

struct SickModeChatCardView: View {
    let card: SickModeChatCard
    let actions: SickModeChatActions
    @State private var severity: SickSeverity?
    @State private var since: SickSince = .now

    init(card: SickModeChatCard, actions: SickModeChatActions) {
        self.card = card
        self.actions = actions
        _severity = State(initialValue: card.severity)
    }

    var body: some View {
        HStack {
            VStack(alignment: .leading, spacing: 8) {
                Label("Sick mode", systemImage: "thermometer.medium").font(.subheadline.weight(.semibold))
                content
            }
            .padding(12)
            .background(Color.orange.opacity(0.12), in: RoundedRectangle(cornerRadius: 16))
            Spacer(minLength: 48)
        }
    }

    @ViewBuilder private var content: some View {
        if case .done(let text) = card.state {
            Text(text).font(.subheadline)
        } else {
            switch card.action {
            case .start where card.alreadyOn:
                Text(SickModeText.title(card.current!)).font(.subheadline)
                let detail = SickModeText.detail(card.current!)
                if !detail.isEmpty { Text(detail).font(.caption).foregroundStyle(.secondary) }
            case .start:
                startContent
            case .end where card.alreadyOff:
                Text(SickModeChatCard.notOnText).font(.subheadline)
            case .end:
                Text("End sick mode?").font(.subheadline)
                Button("End sick mode", role: .destructive, action: actions.onEnd)
                    .buttonStyle(.bordered)
                    .disabled(actions.isBusy)
            }
        }
    }

    @ViewBuilder private var startContent: some View {
        Text("How sick are you?").font(.subheadline)
        ForEach(SickModeText.pickerLevels, id: \.self) { level in
            Button {
                severity = level
            } label: {
                HStack(alignment: .top) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(SickModeText.name(level).capitalized).font(.subheadline.bold())
                        Text(SickModeText.symptoms(level)).font(.caption).foregroundStyle(.secondary)
                    }
                    Spacer()
                    if level == severity { Image(systemName: "checkmark").foregroundStyle(.tint) }
                }
            }
            .buttonStyle(.plain)
            .disabled(actions.isBusy)
        }
        Text("Since when?").font(.subheadline)
        Picker("Since when?", selection: $since) {
            ForEach([SickSince.now, .thisMorning, .yesterday], id: \.self) {
                Text(SickModeText.sinceTitle($0)).tag($0)
            }
        }
        .pickerStyle(.segmented)
        .disabled(actions.isBusy)
        Button("Turn on") {
            if let severity { actions.onTurnOn(severity, since) }
        }
        .buttonStyle(.borderedProminent)
        .disabled(severity == nil || actions.isBusy)
    }
}
