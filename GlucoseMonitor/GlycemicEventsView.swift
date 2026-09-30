import SwiftUI

/// Pure helpers for the history view (unit tested).
enum GlycemicInsightsText {
    static func peakHour(_ histogram: [Int]) -> Int? {
        guard let max = histogram.max(), max > 0 else { return nil }
        return histogram.firstIndex(of: max)
    }

    static func noEffectLine(_ count: Int) -> String? {
        guard count > 0 else { return nil }
        return "\(count) insulin doses in the last 14 days showed no measurable effect. Consider checking your injection sites."
    }

    /// Top-level events grouped by calendar day, newest day first, newest event first within a day.
    static func byDay(_ events: [BackendAPI.GlycemicEvent], calendar: Calendar) -> [(day: Date, events: [BackendAPI.GlycemicEvent])] {
        let grouped = Dictionary(grouping: events.filter { !$0.isChild }) { calendar.startOfDay(for: $0.onsetAt) }
        return grouped.keys.sorted(by: >).map { day in
            (day, grouped[day]!.sorted { $0.onsetAt > $1.onsetAt })
        }
    }
}

/// 30-day history of detected events with a short insights header. Rows open the detail sheet, so old
/// events can still be answered or relabelled.
struct GlycemicEventsView: View {
    @EnvironmentObject private var appState: AppState
    @Environment(\.dismiss) private var dismiss
    @State private var insights: BackendAPI.GlycemicInsights?
    @State private var events: [BackendAPI.GlycemicEvent] = []
    @State private var filter: String?
    @State private var selected: BackendAPI.GlycemicEvent?
    @State private var loadFailed = false

    private var filtered: [BackendAPI.GlycemicEvent] {
        events.filter { $0.state != "DISMISSED" && (filter == nil || $0.category == filter) }
    }

    var body: some View {
        List {
            if let insights {
                Section("Last 30 days") {
                    ForEach(insights.counts.sorted { $0.value > $1.value }, id: \.key) { category, count in
                        HStack {
                            Text(GlycemicCategory.buttonTitle(category))
                            Spacer()
                            if let hour = GlycemicInsightsText.peakHour(insights.hourHistogram[category] ?? []) {
                                Text(String(format: "mostly around %02d:00", hour))
                                    .font(.caption)
                                    .foregroundColor(.secondary)
                            }
                            Text("\(count)").monospacedDigit()
                        }
                    }
                    if let line = GlycemicInsightsText.noEffectLine(insights.noEffectCount14d) {
                        Text(line).font(.footnote).foregroundColor(.purple)
                    }
                }
            }
            if loadFailed {
                Text("Couldn't load detected events. Pull to refresh.").foregroundColor(.secondary)
            }
            ForEach(GlycemicInsightsText.byDay(filtered, calendar: .current), id: \.day) { group in
                Section(group.day.formatted(date: .complete, time: .omitted)) {
                    ForEach(group.events) { e in
                        Button { selected = e } label: {
                            HStack {
                                Circle().fill(GlycemicEventStyle.color(for: e)).frame(width: 8, height: 8)
                                Text(e.displayLabel)
                                Spacer()
                                if e.state == "OPEN" { Text("Unanswered").font(.caption).foregroundColor(.orange) }
                                Text(e.onsetAt, style: .time).font(.caption).foregroundColor(.secondary)
                            }
                        }
                        .foregroundColor(.primary)
                    }
                }
            }
        }
        .navigationTitle("Detected events")
        .toolbar {
            ToolbarItem(placement: .topBarLeading) {
                Menu {
                    Button("All") { filter = nil }
                    ForEach(Array(Set(events.map(\.category))).sorted(), id: \.self) { c in
                        Button(GlycemicCategory.buttonTitle(c)) { filter = c }
                    }
                } label: { Label("Filter", systemImage: "line.3.horizontal.decrease.circle") }
            }
            ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } }
        }
        .refreshable { await load() }
        .task { await load() }
        .sheet(item: $selected, onDismiss: { Task { await load() } }) { e in
            GlycemicEventDetailSheet(event: e).environmentObject(appState)
        }
    }

    private func load() async {
        let now = Date()
        do {
            async let i = BackendAPI.fetchGlycemicInsights(days: 30)
            async let e = BackendAPI.fetchGlycemicEvents(from: now.addingTimeInterval(-30 * 86_400), to: now)
            (insights, events) = try await (i, e)
            loadFailed = false
        } catch {
            loadFailed = true
        }
    }
}
