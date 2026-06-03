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

@main
struct GlucoseMonitorLockWidgetBundle: WidgetBundle {
    var body: some Widget {
        GlucoseLockScreenWidget()
    }
}
