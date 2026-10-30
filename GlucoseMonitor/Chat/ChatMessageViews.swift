import SwiftUI

/// One chat row: user bubble (right), assistant bubble (left), quick-log row with Undo, or error note.
struct ChatMessageRow: View {
    let item: ChatItem
    let displayUnit: String
    let onUndo: () -> Void
    var prompt: GlycemicPromptActions?

    var body: some View {
        switch item.kind {
        case .user(let text, let hasPhoto):
            HStack {
                Spacer(minLength: 48)
                VStack(alignment: .trailing, spacing: 4) {
                    if hasPhoto {
                        Label("Photo", systemImage: "photo")
                            .font(.caption)
                            .foregroundStyle(.white.opacity(0.9))
                    }
                    if !text.isEmpty { Text(text) }
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 8)
                .foregroundStyle(.white)
                .background(Color.accentColor, in: RoundedRectangle(cornerRadius: 16))
            }
        case .assistant(let text):
            HStack {
                Group {
                    if text.isEmpty {
                        TypingDots()
                    } else {
                        Text(text).textSelection(.enabled)
                    }
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 8)
                .foregroundStyle(item.isFailed ? .secondary : .primary)
                .background(Color(.secondarySystemBackground), in: RoundedRectangle(cornerRadius: 16))
                Spacer(minLength: 48)
            }
        case .logged(let entry):
            LoggedRow(entry: entry, displayUnit: displayUnit, onUndo: onUndo)
        case .glycemicPrompt(let event, let text):
            if let prompt {
                GlycemicPromptBubble(event: event, text: text, actions: prompt)
            }
        case .error(let message):
            Label(message, systemImage: "exclamationmark.triangle")
                .font(.footnote)
                .foregroundStyle(.orange)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}

/// What the pinned glycemic question can do; wired to AppState by the overlay.
struct GlycemicPromptActions {
    let isBusy: Bool
    let onAnswer: (_ category: String, _ carbs: Double?, _ insulin: Double?) -> Void
    let onNotSure: () -> Void
    let onNothing: () -> Void
}

/// The glycemic event engine's question as an assistant bubble, with the same one-tap answers the
/// dashboard card had (reuses `GlycemicAnswerButtons`).
struct GlycemicPromptBubble: View {
    let event: BackendAPI.GlycemicEvent
    let text: String
    let actions: GlycemicPromptActions

    var body: some View {
        HStack {
            VStack(alignment: .leading, spacing: 8) {
                Label(event.displayLabel, systemImage: event.isRise ? "arrow.up.right" : "arrow.down.right")
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(GlycemicEventStyle.color(for: event))
                Text(text).textSelection(.enabled)
                GlycemicAnswerButtons(options: event.promptOptions, isBusy: actions.isBusy, onAnswer: actions.onAnswer)
                HStack {
                    Button("Not sure", action: actions.onNotSure)
                    Button("Nothing", action: actions.onNothing)
                }
                .font(.footnote)
                .foregroundColor(.secondary)
                .disabled(actions.isBusy)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .background(Color(.secondarySystemBackground), in: RoundedRectangle(cornerRadius: 16))
            .overlay(RoundedRectangle(cornerRadius: 16).strokeBorder(GlycemicEventStyle.color(for: event).opacity(0.4)))
            Spacer(minLength: 24)
        }
    }
}

/// "✓ Logged 6 U + 48 g · IOB …" with an Undo button; struck through once undone.
struct LoggedRow: View {
    let entry: ChatLoggedEntry
    let displayUnit: String
    let onUndo: () -> Void

    var body: some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: entry.undone ? "arrow.uturn.backward.circle" : "checkmark.circle.fill")
                .foregroundStyle(entry.undone ? Color.secondary : Color.green)
            Text(ChatFormatting.loggedSummary(entry.summary, forecastMin: entry.forecastMin, unit: displayUnit))
                .font(.subheadline)
                .strikethrough(entry.undone)
                .foregroundStyle(entry.undone ? .secondary : .primary)
                .frame(maxWidth: .infinity, alignment: .leading)
            if entry.undone {
                Text("Undone").font(.caption).foregroundStyle(.secondary)
            } else {
                Button("Undo", action: onUndo)
                    .font(.caption.weight(.semibold))
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                    .disabled(entry.undoMessageId == nil)
            }
        }
        .padding(10)
        .background(Color.green.opacity(entry.undone ? 0.04 : 0.10), in: RoundedRectangle(cornerRadius: 12))
    }
}

/// "Today" / "Yesterday" / date label between days.
struct ChatDaySeparator: View {
    let date: Date

    var body: some View {
        Text(label)
            .font(.caption2.weight(.semibold))
            .foregroundStyle(.secondary)
            .frame(maxWidth: .infinity)
            .padding(.vertical, 4)
    }

    private var label: String {
        let cal = Calendar.current
        if cal.isDateInToday(date) { return "Today" }
        if cal.isDateInYesterday(date) { return "Yesterday" }
        return date.formatted(.dateTime.month(.abbreviated).day())
    }
}

/// Placeholder shown while the first reply token is on its way.
struct TypingDots: View {
    @State private var phase = 0
    private let timer = Timer.publish(every: 0.4, on: .main, in: .common).autoconnect()

    var body: some View {
        HStack(spacing: 4) {
            ForEach(0..<3, id: \.self) { i in
                Circle()
                    .frame(width: 6, height: 6)
                    .opacity(phase == i ? 1 : 0.3)
            }
        }
        .foregroundStyle(.secondary)
        .onReceive(timer) { _ in phase = (phase + 1) % 3 }
        .accessibilityLabel("Assistant is replying")
    }
}
