import SwiftUI

/// Detail for one event: label, plain-language summary, timeline, and the same answers while it's open.
struct GlycemicEventDetailSheet: View {
    let event: BackendAPI.GlycemicEvent
    @EnvironmentObject private var appState: AppState
    @Environment(\.dismiss) private var dismiss
    @State private var history: [BackendAPI.GlycemicEventHistoryEntry] = []

    var body: some View {
        NavigationStack {
            List {
                Section {
                    Label(event.displayLabel, systemImage: event.isRise ? "arrow.up.right" : "arrow.down.right")
                        .foregroundStyle(GlycemicEventStyle.color(for: event))
                    Text(GlycemicEventCopy.summary(for: event, displayUnit: appState.preferredGlucoseUnit))
                    Text("\(event.onsetAt.formatted(date: .abbreviated, time: .shortened)) – \(event.windowEnd.formatted(date: .omitted, time: .shortened))")
                        .foregroundColor(.secondary)
                }
                if event.state == "OPEN" && !event.isChild {
                    Section(GlycemicEventCopy.question(for: event)) {
                        GlycemicAnswerButtons(options: event.promptOptions, isBusy: appState.isAnsweringGlycemicPrompt) { category, carbs, insulin in
                            Task {
                                if await appState.answerGlycemicEvent(event, category: category, carbs: carbs, insulin: insulin) {
                                    dismiss()
                                }
                            }
                        }
                        Button("Nothing", role: .destructive) {
                            Task { if await appState.dismissGlycemicEvent(event) { dismiss() } }
                        }
                    }
                }
                if !history.isEmpty {
                    Section("Timeline") {
                        ForEach(Array(history.enumerated()), id: \.offset) { _, h in
                            VStack(alignment: .leading, spacing: 2) {
                                Text(h.kind.capitalized + (h.categoryAfter.map { " · " + GlycemicCategory.buttonTitle($0) } ?? ""))
                                Text("\(h.at.formatted(date: .abbreviated, time: .shortened)) · \(h.actor == "USER" ? "You" : "Detected")")
                                    .font(.caption)
                                    .foregroundColor(.secondary)
                            }
                        }
                    }
                }
            }
            .navigationTitle("Detected event")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } } }
            .task { history = (try? await BackendAPI.fetchGlycemicEventHistory(id: event.id)) ?? [] }
        }
    }
}
