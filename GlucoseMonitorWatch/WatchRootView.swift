import SwiftUI

// MARK: - Main view

struct WatchRootView: View {
    @State private var snapshot: LockScreenWidgetSnapshot? = LockScreenWidgetSnapshot.load()

    private var hasData: Bool { snapshot != nil }

    var body: some View {
        Group {
            if let snap = snapshot {
                GlucoseDisplayView(snapshot: snap, onRefresh: reload)
            } else {
                EmptyStateView(onRefresh: reload)
            }
        }
        .onAppear { reload() }
    }

    private func reload() {
        snapshot = LockScreenWidgetSnapshot.load()
    }
}

// MARK: - Glucose display

private struct GlucoseDisplayView: View {
    let snapshot: LockScreenWidgetSnapshot
    let onRefresh: () -> Void

    private var glucoseMmol: Double? { snapshot.glucoseMmolForColoring() }

    private var glucoseColor: Color {
        guard let mmol = glucoseMmol else { return .primary }
        if mmol < 3.5 || mmol >= 14 { return .red }
        if mmol < 4.0 || mmol >= 10.0 { return .yellow }
        return .green
    }

    private var glucoseText: String {
        guard let v = snapshot.glucoseValue else { return "--" }
        let unit = snapshot.glucoseUnit
        if unit.lowercased().contains("mg") {
            return String(format: "%.0f", v)
        }
        return String(format: "%.1f", v)
    }

    private var unitText: String {
        snapshot.glucoseUnit.lowercased().contains("mg") ? "mg/dL" : "mmol/L"
    }

    private var predictionText: String {
        guard let pred = snapshot.twoHourPredictionMmol else { return "--" }
        let unit = snapshot.glucoseUnit
        if unit.lowercased().contains("mg") {
            return String(format: "%.0f", pred * 18.018)
        }
        return String(format: "%.1f", pred)
    }

    private var readingAge: String {
        let elapsed = -snapshot.readingAgeStart.timeIntervalSinceNow
        if elapsed < 60 { return "now" }
        let mins = Int(elapsed / 60)
        if mins < 60 { return "\(mins)m ago" }
        return "\(mins / 60)h \(mins % 60)m ago"
    }

    var body: some View {
        ScrollView {
            VStack(spacing: 8) {

                // ── Current glucose ───────────────────────────────────────────
                VStack(spacing: 2) {
                    HStack(alignment: .firstTextBaseline, spacing: 4) {
                        Text(glucoseText)
                            .font(.system(size: 44, weight: .bold, design: .rounded))
                            .foregroundColor(glucoseColor)
                            .minimumScaleFactor(0.7)
                            .lineLimit(1)

                        if let arrow = snapshot.trendArrow, !arrow.isEmpty {
                            Text(trendEmoji(arrow))
                                .font(.title2)
                                .foregroundColor(glucoseColor)
                        }
                    }

                    Text(unitText)
                        .font(.caption2)
                        .foregroundColor(.secondary)
                }

                Divider()

                // ── 2-hour prediction ─────────────────────────────────────────
                VStack(spacing: 2) {
                    Text("2h Prediction")
                        .font(.caption2)
                        .foregroundColor(.secondary)
                    Text(predictionText)
                        .font(.system(size: 24, weight: .semibold, design: .rounded))
                        .foregroundColor(.primary)
                        .minimumScaleFactor(0.8)
                        .lineLimit(1)
                }

                Divider()

                // ── Reading age + refresh ─────────────────────────────────────
                VStack(spacing: 6) {
                    Text(readingAge)
                        .font(.caption2)
                        .foregroundColor(.secondary)

                    Button(action: onRefresh) {
                        Label("Refresh", systemImage: "arrow.clockwise")
                            .font(.caption)
                    }
                    .buttonStyle(.borderedProminent)
                    .tint(.blue.opacity(0.8))
                }
            }
            .padding(.horizontal, 4)
            .padding(.vertical, 6)
        }
    }
}

// MARK: - Empty state

private struct EmptyStateView: View {
    let onRefresh: () -> Void

    var body: some View {
        VStack(spacing: 10) {
            Image(systemName: "waveform.path.ecg")
                .font(.title2)
                .foregroundColor(.secondary)
            Text("Open the iPhone app to sync glucose data.")
                .font(.caption2)
                .foregroundColor(.secondary)
                .multilineTextAlignment(.center)
            Button("Refresh", action: onRefresh)
                .font(.caption)
                .buttonStyle(.borderedProminent)
                .tint(.blue.opacity(0.8))
        }
        .padding()
    }
}

// MARK: - Trend arrow helper

/// Maps LibreLinkUp / Nightscout trend strings to Unicode arrows.
private func trendEmoji(_ arrow: String) -> String {
    switch arrow.lowercased() {
    case "doubleup", "rapidlyincreasing":       return "⇈"
    case "singleup":                            return "↑"
    case "fortyfiveup", "slowlyincreasing":     return "↗"
    case "flat", "steady":                      return "→"
    case "fortyfivedown", "slowlydecreasing":   return "↘"
    case "singledown":                          return "↓"
    case "doubledown", "rapidlydecreasing":     return "⇊"
    default:
        // Return raw value if it's already an arrow/symbol; otherwise "~"
        let scalars = arrow.unicodeScalars
        if let first = scalars.first, first.properties.isEmoji { return arrow }
        return "~"
    }
}
