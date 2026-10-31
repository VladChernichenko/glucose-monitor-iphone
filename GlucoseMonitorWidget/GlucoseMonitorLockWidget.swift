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

    /// Value + trend large on the left, the 2h forecast under it, IOB/COB/age small on the right, and the
    /// 4h history as a thick bright line underneath. No frosted backing: the Lock Screen renders accessory
    /// widgets in one tint by brightness, so black reads as the (dark) wallpaper and the bright green line
    /// as the brightest tint; full colour shows wherever the system allows it.
    private var rectangular: some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack(alignment: .top, spacing: 6) {
                VStack(alignment: .leading, spacing: -2) {
                    HStack(alignment: .firstTextBaseline, spacing: 3) {
                        Text(stale ? "--" : currentText).font(.system(size: 30, weight: .heavy, design: .rounded))
                        if !stale {
                            Text(trendText).font(.system(size: 18, weight: .heavy))
                        }
                    }
                    Text(stale ? "No new data" : forecastText.map { "2h \($0)" } ?? " ")
                        .font(.system(size: 12, weight: .bold, design: .rounded))
                }
                Spacer(minLength: 0)
                VStack(alignment: .trailing, spacing: 0) {
                    Text("IOB \(iobText)")
                    Text("COB \(cobText)")
                    Text(ageText)
                }
                .font(.system(size: 11, weight: .bold, design: .rounded))
            }
            HighContrastChartLine(points: snapshot.chartPointsMmol())
                .frame(height: 16)
        }
        .lineLimit(1)
        .minimumScaleFactor(0.6)
        .monospacedDigit()
        .padding(.horizontal, 4)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(Color.black)
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

/// The last hours of readings as one thick, bright green line (no axes, no grid) scaled to its own range.
private struct HighContrastChartLine: View {
    let points: [LockScreenWidgetSnapshot.ChartPoint]
    private static let green = Color(red: 0.2, green: 1, blue: 0.4)

    var body: some View {
        Canvas { ctx, size in
            guard points.count >= 2, let t0 = points.first?.time, let t1 = points.last?.time else { return }
            let span = max(t1.timeIntervalSince(t0), 1)
            let values = points.map(\.mmol)
            let low = (values.min() ?? 4) - 0.3
            let range = max((values.max() ?? 10) + 0.3 - low, 1)
            var line = Path()
            for (i, p) in points.enumerated() {
                let x = CGFloat(p.time.timeIntervalSince(t0) / span) * size.width
                let y = size.height - CGFloat((p.mmol - low) / range) * size.height
                i == 0 ? line.move(to: CGPoint(x: x, y: y)) : line.addLine(to: CGPoint(x: x, y: y))
            }
            ctx.stroke(line, with: .color(Self.green),
                       style: StrokeStyle(lineWidth: 3, lineCap: .round, lineJoin: .round))
        }
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
