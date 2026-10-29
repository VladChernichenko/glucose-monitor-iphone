import SwiftUI
import WidgetKit

struct GlucoseWidgetEntry: TimelineEntry {
    let date: Date
    let snapshot: LockScreenWidgetSnapshot?
}

struct GlucoseWidgetProvider: TimelineProvider {
    /// Align widget data refresh with app glucose polling (~5 min).
    private static let dataRefreshInterval: TimeInterval = 5 * 60
    /// Fallback timeline steps so the age label still advances if `.timer` text is paused.
    private static let timerFallbackSteps = 30
    private static let timerFallbackStepSeconds = 10

    func placeholder(in context: Context) -> GlucoseWidgetEntry {
        GlucoseWidgetEntry(date: Date(), snapshot: .preview)
    }

    func getSnapshot(in context: Context, completion: @escaping (GlucoseWidgetEntry) -> Void) {
        completion(GlucoseWidgetEntry(date: Date(), snapshot: LockScreenWidgetSnapshot.load()))
    }

    func getTimeline(in context: Context, completion: @escaping (Timeline<GlucoseWidgetEntry>) -> Void) {
        let snapshot = LockScreenWidgetSnapshot.load()
        let now = Date()
        var entries: [GlucoseWidgetEntry] = [GlucoseWidgetEntry(date: now, snapshot: snapshot)]
        if snapshot != nil {
            for step in 1...Self.timerFallbackSteps {
                let offset = step * Self.timerFallbackStepSeconds
                let date = now.addingTimeInterval(TimeInterval(offset))
                entries.append(GlucoseWidgetEntry(date: date, snapshot: snapshot))
            }
        }
        let reload = now.addingTimeInterval(Self.dataRefreshInterval)
        completion(Timeline(entries: entries, policy: .after(reload)))
    }
}

struct GlucoseLockScreenWidget: Widget {
    static let kind = LockScreenWidgetSnapshot.widgetKind

    var body: some WidgetConfiguration {
        StaticConfiguration(kind: Self.kind, provider: GlucoseWidgetProvider()) { entry in
            GlucoseLockWidgetEntryView(entry: entry)
        }
        .containerBackgroundRemovable(false)
        .contentMarginsDisabled()
        .description("Glucose, forecast, and chart. Refreshes when the app syncs in foreground or background.")
        .supportedFamilies([
            .accessoryRectangular,
            .accessoryCircular,
            .accessoryInline,
            .systemSmall,
            .systemMedium,
            .systemLarge,
            .systemExtraLarge,
        ])
    }
}

/// Lock Screen widget built for a one-second glance: the dashboard's key numbers (now, trend, 2h
/// forecast, IOB, COB, reading age) in large, full-strength type on the system backing, so they stay
/// readable in the Lock Screen's single-tint rendering over any wallpaper.
struct GlucoseHighContrastWidget: Widget {
    static let kind = LockScreenWidgetSnapshot.highContrastWidgetKind

    var body: some WidgetConfiguration {
        StaticConfiguration(kind: Self.kind, provider: GlucoseWidgetProvider()) { entry in
            HighContrastGlucoseView(entry: entry)
        }
        .configurationDisplayName("Glucose - High Contrast")
        .description("Big, high-contrast glucose, trend, 2h forecast, IOB and COB for the Lock Screen.")
        .supportedFamilies([.accessoryRectangular, .accessoryCircular, .accessoryInline])
    }
}

struct HighContrastGlucoseView: View {
    @Environment(\.widgetFamily) private var family
    let entry: GlucoseWidgetEntry

    private var snapshot: LockScreenWidgetSnapshot { entry.snapshot ?? .empty }
    /// Old or flagged data: like the dashboard, no current value or forecast - only how old it is.
    private var stale: Bool { snapshot.glucoseValue == nil || snapshot.isStale(at: entry.date) }
    private var isMgdl: Bool { snapshot.glucoseUnit.lowercased().contains("mg") }

    var body: some View {
        Group {
            switch family {
            case .accessoryCircular: circular
            case .accessoryInline: inline
            default: rectangular
            }
        }
        .containerBackground(for: .widget) { Color.clear }
    }

    // MARK: Layouts

    private var rectangular: some View {
        ZStack {
            AccessoryWidgetBackground()
                .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
            VStack(alignment: .leading, spacing: 0) {
                if stale {
                    HStack(alignment: .firstTextBaseline, spacing: 6) {
                        Text("--").font(.system(size: 34, weight: .heavy, design: .rounded))
                        Text("No new data").font(.system(size: 15, weight: .bold, design: .rounded))
                    }
                } else {
                    HStack(alignment: .firstTextBaseline, spacing: 4) {
                        Text(currentText).font(.system(size: 36, weight: .heavy, design: .rounded))
                        Text(trendText).font(.system(size: 24, weight: .heavy))
                        if let forecast = forecastText {
                            Text(forecast).font(.system(size: 28, weight: .heavy, design: .rounded))
                            Text("2h").font(.system(size: 12, weight: .heavy, design: .rounded))
                        }
                    }
                }
                HStack(spacing: 8) {
                    Text("IOB \(iobText)")
                    Text("COB \(cobText)")
                    Spacer(minLength: 0)
                    Text(ageText)
                }
                .font(.system(size: 14, weight: .bold, design: .rounded))
            }
            .lineLimit(1)
            .minimumScaleFactor(0.6)
            .monospacedDigit()
            .padding(.horizontal, 8)
            .padding(.vertical, 2)
        }
    }

    private var circular: some View {
        ZStack {
            AccessoryWidgetBackground()
            VStack(spacing: -2) {
                Text(stale ? "--" : currentText)
                    .font(.system(size: 24, weight: .heavy, design: .rounded))
                Text(stale ? ageText : trendText)
                    .font(.system(size: 14, weight: .heavy, design: .rounded))
            }
            .lineLimit(1)
            .minimumScaleFactor(0.5)
            .monospacedDigit()
            .padding(4)
        }
    }

    private var inline: some View {
        if stale {
            Text("Glucose -- · \(ageText)")
        } else {
            Text("\(currentText) \(trendText)\(forecastText.map { " \($0)" } ?? "") · IOB \(iobText) · \(ageText)")
        }
    }

    // MARK: Text

    private func format(_ value: Double) -> String {
        isMgdl ? String(format: "%.0f", value) : String(format: "%.1f", value)
    }

    private var currentText: String { snapshot.glucoseValue.map(format) ?? "--" }

    /// The CGM trend arrow, as on the dashboard; a flat arrow when the sensor gives none.
    private var trendText: String {
        guard let arrow = snapshot.trendArrow, !arrow.isEmpty, arrow != "?" else { return "\u{2192}" }
        return arrow
    }

    private var forecastText: String? {
        snapshot.twoHourPredictionMmol.map { format(GlucoseUnit.fromMmol($0, displayUnit: snapshot.glucoseUnit)) }
    }

    private var iobText: String { snapshot.iobUnits.map { String(format: "%.1fu", $0) } ?? "--" }

    private var cobText: String { snapshot.cobGrams.map { String(format: "%.0fg", $0) } ?? "--" }

    /// Minutes since the reading, from the timeline entry's date so it advances on the Lock Screen.
    private var ageText: String {
        guard snapshot.glucoseValue != nil else { return "open app" }
        let minutes = Int(entry.date.timeIntervalSince(snapshot.savedAt) / 60)
        if minutes < 1 { return "now" }
        if minutes < 60 { return "\(minutes)m ago" }
        return "\(minutes / 60)h ago"
    }
}

@main
struct GlucoseMonitorLockWidgetBundle: WidgetBundle {
    var body: some Widget {
        GlucoseLockScreenWidget()
        GlucoseHighContrastWidget()
    }
}

#Preview("High contrast", as: .accessoryRectangular) {
    GlucoseHighContrastWidget()
} timeline: {
    GlucoseWidgetEntry(date: .now, snapshot: .preview)
    GlucoseWidgetEntry(date: .now.addingTimeInterval(20 * 60), snapshot: .preview)
}
