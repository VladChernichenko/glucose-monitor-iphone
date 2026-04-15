import SwiftUI
import WidgetKit

struct GlucoseWidgetEntry: TimelineEntry {
    let date: Date
    let snapshot: LockScreenWidgetSnapshot?
}

struct GlucoseWidgetProvider: TimelineProvider {
    func placeholder(in context: Context) -> GlucoseWidgetEntry {
        GlucoseWidgetEntry(date: Date(), snapshot: .preview)
    }

    func getSnapshot(in context: Context, completion: @escaping (GlucoseWidgetEntry) -> Void) {
        completion(GlucoseWidgetEntry(date: Date(), snapshot: LockScreenWidgetSnapshot.load()))
    }

    func getTimeline(in context: Context, completion: @escaping (Timeline<GlucoseWidgetEntry>) -> Void) {
        let entry = GlucoseWidgetEntry(date: Date(), snapshot: LockScreenWidgetSnapshot.load())
        let next = Calendar.current.date(byAdding: .minute, value: 15, to: Date()) ?? Date().addingTimeInterval(900)
        completion(Timeline(entries: [entry], policy: .after(next)))
    }
}

struct GlucoseLockScreenWidget: Widget {
    static let kind = LockScreenWidgetSnapshot.widgetKind

    var body: some WidgetConfiguration {
        StaticConfiguration(kind: Self.kind, provider: GlucoseWidgetProvider()) { entry in
            GlucoseLockWidgetEntryView(entry: entry)
        }
        // Lock Screen accessory widgets omit container backgrounds by default; false keeps the opaque fill.
        .containerBackgroundRemovable(false)
        // Use the system slot edge-to-edge; slot width is still fixed by iOS (use the center row below the time for the widest lock placement).
        .contentMarginsDisabled()
        .description("Lock Screen: place in the wide center row below the time for maximum width. Home Screen: Large is full-width. Open the app to refresh.")
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
