import SwiftUI
import WidgetKit

// The watch-face complication and Smart Stack widget. It never calls the network: it draws the glance the
// watch app last stored, and the app reloads it after every fetch.

struct GlanceEntry: TimelineEntry {
    let date: Date
    let presentation: GlancePresentation?
    let relevance: TimelineEntryRelevance?
}

struct GlanceProvider: TimelineProvider {
    func placeholder(in context: Context) -> GlanceEntry {
        GlanceEntry(date: Date(), presentation: nil, relevance: nil)
    }

    func getSnapshot(in context: Context, completion: @escaping (GlanceEntry) -> Void) {
        completion(Self.entries(from: Date())[0])
    }

    func getTimeline(in context: Context, completion: @escaping (Timeline<GlanceEntry>) -> Void) {
        let now = Date()
        completion(Timeline(entries: Self.entries(from: now), policy: .after(now.addingTimeInterval(15 * 60))))
    }

    /// One entry a minute for 15 min, so the age, greying and expired advice move on without a fetch.
    static func entries(from now: Date) -> [GlanceEntry] {
        let stored = GlanceStore.load()
        let failed = GlanceStore.lastAttemptFailed()
        let unit = GlucoseMonitorAPI.sharedDefaults()
            .string(forKey: GlucoseMonitorAPI.StorageKey.glucoseDisplayUnit) ?? "mmol/L"
        return (0...15).map { minute in
            let date = now.addingTimeInterval(Double(minute) * 60)
            let p = stored.map {
                GlancePresentation(glance: $0.glance, now: date, fetchedAt: $0.fetchedAt,
                                   lastAttemptFailed: failed, unit: unit)
            }
            let urgent = p?.strip?.urgent == true
            return GlanceEntry(date: date, presentation: p, relevance: TimelineEntryRelevance(score: urgent ? 100 : 0))
        }
    }
}

struct GlanceComplicationView: View {
    @Environment(\.widgetFamily) private var family
    let entry: GlanceEntry

    private var p: GlancePresentation? { entry.presentation }
    private var showsValue: Bool { p.map { !$0.isStale } ?? false }
    private var value: String { showsValue ? p!.valueText : "--" }
    private var arrow: String { showsValue ? p!.arrow : "" }

    private var age: String {
        guard let at = p?.readingAt else { return "" }
        let minutes = max(0, Int(entry.date.timeIntervalSince(at) / 60))
        return minutes < 60 ? "\(minutes)m" : "\(minutes / 60)h"
    }

    private var tint: Color {
        guard showsValue, let p else { return .gray }
        switch p.rangeColor {
        case .urgent: return .red
        case .low, .high: return .yellow
        case .inRange: return .green
        case .none: return .gray
        }
    }

    var body: some View {
        Group {
            switch family {
            case .accessoryCircular: circular
            case .accessoryInline: Text("\(value) \(arrow) · \(age)")
            case .accessoryCorner:
                Text(value)
                    .font(.system(size: 20, weight: .bold, design: .rounded))
                    .foregroundStyle(tint)
                    .widgetLabel(arrow.isEmpty ? age : "\(arrow) \(age)")
            default: rectangular
            }
        }
        .containerBackground(for: .widget) { Color.clear }
    }

    private var circular: some View {
        VStack(spacing: 0) {
            Text(value)
                .font(.system(size: 18, weight: .bold, design: .rounded))
                .minimumScaleFactor(0.5)
                .lineLimit(1)
            Text(arrow.isEmpty ? age : arrow)
                .font(.caption2)
        }
        .foregroundStyle(tint)
    }

    private var rectangular: some View {
        VStack(alignment: .leading, spacing: 1) {
            HStack(alignment: .firstTextBaseline, spacing: 4) {
                Text(value)
                    .font(.system(size: 22, weight: .bold, design: .rounded))
                Text(arrow)
                    .font(.headline)
                Spacer(minLength: 0)
                Text(age)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
            .foregroundStyle(tint)
            if let line = secondLine {
                Text(line)
                    .font(.caption2)
                    .lineLimit(2)
            }
        }
    }

    /// The strip headline when there is an alert, else why the data is stale, else the 2 h prediction.
    private var secondLine: String? {
        guard let p else { return "Open Glucose on your watch" }
        if let strip = p.strip { return strip.title }
        if let stale = p.stale { return stale.title }
        return p.predictionText.map { "2h \($0) \(p.unitLabel)" }
    }
}

struct GlucoseComplication: Widget {
    static let kind = "GlucoseWatchComplication"

    var body: some WidgetConfiguration {
        StaticConfiguration(kind: Self.kind, provider: GlanceProvider()) { entry in
            GlanceComplicationView(entry: entry)
        }
        .configurationDisplayName("Glucose")
        .description("Current glucose, trend and alerts.")
        .supportedFamilies([.accessoryCircular, .accessoryRectangular, .accessoryInline, .accessoryCorner])
    }
}

@main
struct GlucoseComplicationBundle: WidgetBundle {
    var body: some Widget {
        GlucoseComplication()
    }
}
