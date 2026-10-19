import SwiftUI
import Charts

/// "Forecast at each log": the empirical twin's forecast from one logged dose or meal against what the
/// CGM did, with ← / → (or a swipe) to step through the history.
struct TwinForecastView: View {
    @EnvironmentObject private var appState: AppState
    @Environment(\.dismiss) private var dismiss

    @State private var anchors: [BackendAPI.ForecastAnchor] = []
    @State private var index = 0
    @State private var forecasts: [String: BackendAPI.AnchorForecast] = [:]
    @State private var message: String?
    @State private var loading = true

    private static let targetLowMmol = 3.9
    private static let targetHighMmol = 10.0

    private var current: BackendAPI.ForecastAnchor? { anchors.indices.contains(index) ? anchors[index] : nil }
    private var forecast: BackendAPI.AnchorForecast? { current.flatMap { forecasts[$0.noteId] } }
    private var unit: String { appState.preferredGlucoseUnit }
    private var isMgdl: Bool { GlucoseUnit.isMgdl(unit) }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                if let message {
                    Text(message).font(.subheadline).foregroundStyle(.secondary)
                } else if loading && anchors.isEmpty {
                    ProgressView().frame(maxWidth: .infinity)
                } else {
                    navigator
                    chartSection
                    stats
                }
            }
            .padding()
        }
        .navigationTitle("Forecast at each log")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .principal) {
                HStack(spacing: 8) {
                    Text("Forecast at each log").font(.headline)
                    if forecast?.pending == true {
                        Text("pending")
                            .font(.caption.weight(.semibold))
                            .padding(.horizontal, 8).padding(.vertical, 2)
                            .background(Color(.systemGray5), in: Capsule())
                            .foregroundStyle(.secondary)
                    }
                }
            }
            ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } }
        }
        .task { await loadAnchors() }
    }

    // MARK: Navigator

    private var navigator: some View {
        HStack(spacing: 8) {
            Button { step(-1) } label: { Image(systemName: "arrow.left").frame(width: 36, height: 36) }
                .buttonStyle(.bordered)
                .disabled(index <= 0)
                .accessibilityLabel("Older log")

            Menu {
                Picker("Log", selection: Binding(get: { index }, set: { select($0) })) {
                    ForEach(anchors.indices.reversed(), id: \.self) { i in
                        Text(TwinForecastText.title(anchors[i])).tag(i)
                    }
                }
            } label: {
                HStack {
                    Text(current.map(TwinForecastText.title) ?? "")
                        .lineLimit(1)
                        .frame(maxWidth: .infinity, alignment: .leading)
                    Image(systemName: "chevron.up.chevron.down").font(.caption)
                }
                .padding(.horizontal, 10).frame(height: 36)
                .background(Color(.secondarySystemBackground), in: RoundedRectangle(cornerRadius: 8))
            }
            .foregroundStyle(.primary)

            Button { step(1) } label: { Image(systemName: "arrow.right").frame(width: 36, height: 36) }
                .buttonStyle(.bordered)
                .disabled(index >= anchors.count - 1)
                .accessibilityLabel("Newer log")
        }
    }

    // MARK: Chart

    @ViewBuilder
    private var chartSection: some View {
        if let f = forecast {
            if f.forecast.isEmpty {
                Text("No sensor reading at this log, so there is no forecast from it.")
                    .font(.subheadline).foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, minHeight: 120)
            }
            chart(f)
                .frame(height: 280)
                .gesture(DragGesture(minimumDistance: 30).onEnded { g in
                    if g.translation.width < -40 { step(1) } else if g.translation.width > 40 { step(-1) }
                })
            legend(f)
        } else {
            ProgressView().frame(maxWidth: .infinity, minHeight: 280)
        }
    }

    private func chart(_ f: BackendAPI.AnchorForecast) -> some View {
        let domain = yDomain(f)
        let markerTop = domain.lowerBound + (domain.upperBound - domain.lowerBound) * 0.06
        let start = f.actual.first?.time ?? f.anchor.time.addingTimeInterval(-3600)
        let end = f.anchor.time.addingTimeInterval(4 * 3600)
        return Chart {
            RectangleMark(xStart: .value("s", start), xEnd: .value("e", end),
                          yStart: .value("lo", v(Self.targetLowMmol)), yEnd: .value("hi", v(Self.targetHighMmol)))
                .foregroundStyle(Color.green.opacity(0.12))
            RuleMark(y: .value("low", v(Self.targetLowMmol)))
                .foregroundStyle(Color.red.opacity(0.7))
                .lineStyle(StrokeStyle(lineWidth: 1, dash: [4, 3]))

            ForEach(f.forecast) { p in
                AreaMark(x: .value("Time", p.time), yStart: .value("Lower", v(p.lower)), yEnd: .value("Upper", v(p.upper)))
                    .interpolationMethod(.monotone)
                    .foregroundStyle(Color.blue.opacity(0.13))
            }
            ForEach(f.forecast) { p in
                LineMark(x: .value("Time", p.time), y: .value("Glucose", v(p.glucose)), series: .value("Series", "forecast"))
                    .interpolationMethod(.monotone)
                    .foregroundStyle(Color.blue)
                    .lineStyle(StrokeStyle(lineWidth: 3))
            }
            ForEach(f.actual) { r in
                LineMark(x: .value("Time", r.time), y: .value("Glucose", v(r.glucose)), series: .value("Series", "actual"))
                    .foregroundStyle(Color.primary.opacity(0.8))
                PointMark(x: .value("Time", r.time), y: .value("Glucose", v(r.glucose)))
                    .symbolSize(14)
                    .foregroundStyle(Color.primary.opacity(0.8))
            }

            RuleMark(x: .value("Log", f.anchor.time))
                .foregroundStyle(Color.primary.opacity(0.6))
                .lineStyle(StrokeStyle(lineWidth: 1, dash: [3, 3]))

            ForEach(f.markers) { m in
                RuleMark(x: .value("Marker", m.time), yStart: .value("b", domain.lowerBound), yEnd: .value("t", markerTop))
                    .foregroundStyle(TwinForecastText.color(m.kind))
                    .lineStyle(StrokeStyle(lineWidth: 3))
                    .annotation(position: .bottom, spacing: 2) {
                        Text(TwinForecastText.markerLabel(m))
                            .font(.system(size: 9, weight: .semibold))
                            .foregroundStyle(TwinForecastText.color(m.kind))
                    }
            }
        }
        .chartXScale(domain: start...end)
        .chartYScale(domain: domain)
        .chartXAxis {
            AxisMarks(values: .stride(by: .hour)) { _ in
                AxisGridLine()
                AxisValueLabel(format: .dateTime.hour().minute())
            }
        }
        .chartYAxis { AxisMarks(position: .leading) }
    }

    private func legend(_ f: BackendAPI.AnchorForecast) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 14) {
                legendItem(Color.blue, "Forecast from this log")
                legendItem(Color.blue.opacity(0.25), "Likely range (\(Int((f.coverage * 100).rounded()))% of past forecasts)", thick: true)
            }
            HStack(spacing: 14) {
                legendItem(Color.primary.opacity(0.8), "CGM (actual)")
                legendItem(TwinForecastText.color("INSULIN"), "Rapid")
                legendItem(TwinForecastText.color("CARBS"), "Carbs")
                legendItem(TwinForecastText.color("BASAL"), "Basal")
            }
        }
        .font(.caption)
        .foregroundStyle(.secondary)
    }

    private func legendItem(_ color: Color, _ text: String, thick: Bool = false) -> some View {
        HStack(spacing: 4) {
            RoundedRectangle(cornerRadius: 1).fill(color).frame(width: 16, height: thick ? 8 : 3)
            Text(text).lineLimit(1).minimumScaleFactor(0.8)
        }
    }

    // MARK: Stats

    @ViewBuilder
    private var stats: some View {
        if let f = forecast {
            LazyVGrid(columns: [GridItem(.flexible(), alignment: .leading), GridItem(.flexible(), alignment: .leading)],
                      spacing: 14) {
                stat(value: f.startGlucose.map(fmt) ?? "-", caption: "AT LOG", hit: nil)
                ForEach(f.checks, id: \.minute) { c in
                    stat(value: "\(c.forecast.map(fmt) ?? "-") / \(c.actual.map(fmt) ?? "…")",
                         caption: "+\(c.minute / 60) H FCST / ACTUAL", hit: c.hit)
                }
            }
        }
    }

    private func stat(value: String, caption: String, hit: Bool?) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 6) {
                Text(value).font(.system(.title2, design: .monospaced).weight(.semibold))
                if let hit {
                    Text(hit ? "hit" : "miss")
                        .font(.caption2.weight(.bold))
                        .padding(.horizontal, 6).padding(.vertical, 2)
                        .background((hit ? Color.green : Color.red).opacity(0.18), in: Capsule())
                        .foregroundStyle(hit ? Color.green : Color.red)
                }
            }
            Text(caption).font(.caption).foregroundStyle(.secondary)
        }
    }

    // MARK: Data

    private func loadAnchors() async {
        loading = true
        defer { loading = false }
        do {
            anchors = try await BackendAPI.fetchForecastAnchors(days: 30)
            if anchors.isEmpty {
                message = "No doses or meals logged in the last 30 days."
                return
            }
            index = anchors.count - 1
            await loadForecast()
        } catch GlucoseMonitorAPI.APIError.httpStatus(404, _) {
            message = "The empirical twin is turned off on the server (app.features.empirical-twin-enabled)."
        } catch {
            message = "Couldn't load your logs. Pull to try again later."
        }
    }

    private func loadForecast() async {
        guard let a = current, forecasts[a.noteId] == nil else { return }
        do {
            forecasts[a.noteId] = try await BackendAPI.fetchAnchorForecast(noteId: a.noteId)
        } catch {
            message = "Couldn't load the forecast for this log."
        }
    }

    private func step(_ delta: Int) { select(index + delta) }

    private func select(_ i: Int) {
        guard anchors.indices.contains(i), i != index else { return }
        index = i
        Task { await loadForecast() }
    }

    // MARK: Units

    private func v(_ mmol: Double) -> Double { GlucoseUnit.fromMmol(mmol, displayUnit: unit) }

    private func fmt(_ mmol: Double) -> String {
        isMgdl ? String(format: "%.0f", v(mmol)) : String(format: "%.1f", v(mmol))
    }

    private func yDomain(_ f: BackendAPI.AnchorForecast) -> ClosedRange<Double> {
        let values = f.forecast.flatMap { [$0.lower, $0.upper] } + f.actual.map(\.glucose)
            + [Self.targetLowMmol, Self.targetHighMmol]
        let lo = max(0, (values.min() ?? 3) - 1.5), hi = (values.max() ?? 12) + 1
        return v(lo)...v(hi)
    }
}

/// Pure formatting helpers for the forecast view.
enum TwinForecastText {
    private static let titleFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "MMM d, HH:mm"
        return f
    }()

    /// "Oct 19, 17:33 · Almonds" (falls back to the amounts when the note has no text).
    static func title(_ a: BackendAPI.ForecastAnchor) -> String {
        let label = a.label?.trimmingCharacters(in: .whitespacesAndNewlines)
        let what = (label?.isEmpty == false ? label : nil) ?? amounts(a)
        return "\(titleFormatter.string(from: a.time)) · \(what)"
    }

    static func amounts(_ a: BackendAPI.ForecastAnchor) -> String {
        [a.insulin.map { "\(number($0)) U" }, a.carbs.map { "\(number($0)) g" }]
            .compactMap { $0 }.joined(separator: " + ")
    }

    static func markerLabel(_ m: BackendAPI.AnchorForecast.Marker) -> String {
        switch m.kind {
        case "CARBS": return "\(number(m.amount))g"
        case "ACTIVITY": return "\(number(m.amount))′"
        default: return "\(number(m.amount))U"
        }
    }

    static func color(_ kind: String) -> Color {
        switch kind {
        case "INSULIN": return .blue
        case "BASAL": return .purple
        case "CARBS": return .orange
        default: return .green
        }
    }

    private static func number(_ v: Double) -> String {
        v.rounded() == v ? String(Int(v)) : String(format: "%.1f", v)
    }
}
