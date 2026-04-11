import Charts
import SwiftUI

// MARK: - Chart model

struct GlucoseChartPoint: Identifiable, Equatable {
    let time: Date
    let mmol: Double
    var id: String { String(format: "%.3f_%.2f", time.timeIntervalSince1970, mmol) }
}

struct PredictionChartPoint: Identifiable, Equatable {
    let time: Date
    let mmol: Double
    var id: String { String(format: "p_%.3f", time.timeIntervalSince1970) }
}

// MARK: - Pre-bolus timer (matches web `EnhancedDashboard` logic)

enum PreBolusTimer {
    static func state(notes: [BackendAPI.GlucoseNote], now: Date) -> (visible: Bool, label: String) {
        let sorted = notes
            .filter { $0.timestamp != nil }
            .sorted { ($0.timestamp ?? .distantPast) < ($1.timestamp ?? .distantPast) }

        let preBolusNotes = sorted
            .filter { $0.insulin > 0 }
            .filter {
                let m = $0.meal.lowercased()
                return m == "pre-bolus" || m == "prebolus"
            }
            .sorted { ($0.timestamp ?? .distantPast) > ($1.timestamp ?? .distantPast) }

        guard let latest = preBolusNotes.first, let bolusTime = latest.timestamp else {
            return (false, "--")
        }

        let mealAfter = sorted.first { note in
            guard let nt = note.timestamp else { return false }
            if nt < bolusTime { return false }
            if note.carbs <= 0 { return false }
            let mt = note.meal.lowercased()
            return mt != "correction" && mt != "pre-bolus" && mt != "prebolus"
        }

        if mealAfter != nil {
            return (false, "--")
        }

        let elapsed = max(0, Int(now.timeIntervalSince(bolusTime)))
        let minutes = elapsed / 60
        let seconds = elapsed % 60
        return (true, String(format: "%d:%02d", minutes, seconds))
    }
}

// MARK: - Glucose chart + prediction + notes

struct GlucoseHistoryChart: View {
    let history: [GlucoseChartPoint]
    let prediction: [PredictionChartPoint]
    let notes: [BackendAPI.GlucoseNote]

    /// mmol/L band matching common target range (shown like Libre-style charts).
    private static let targetLowMmol: Double = 4
    private static let targetHighMmol: Double = 10

    private var xDomain: ClosedRange<Date>? {
        let t1 = history.map(\.time)
        let t2 = prediction.map(\.time)
        let all = t1 + t2
        guard let mn = all.min(), let mx = all.max(), mn <= mx else { return nil }
        if mn == mx {
            return mn.addingTimeInterval(-1800)...mx.addingTimeInterval(1800)
        }
        return mn...mx
    }

    private var notesOnChart: [BackendAPI.GlucoseNote] {
        guard let domain = xDomain else { return [] }
        return notes
            .filter { note in
                guard let t = note.timestamp else { return false }
                return t >= domain.lowerBound && t <= domain.upperBound
            }
            .sorted { ($0.timestamp ?? .distantPast) < ($1.timestamp ?? .distantPast) }
    }

    var body: some View {
        Group {
            if history.isEmpty && prediction.isEmpty {
                Text("No chart data yet")
                    .font(.subheadline)
                    .foregroundColor(.secondary)
                    .frame(maxWidth: .infinity, minHeight: 160)
            } else {
                chartCore
                    .chartXAxis {
                        AxisMarks(values: .automatic) { _ in
                            AxisGridLine()
                            AxisTick()
                            AxisValueLabel(format: .dateTime.hour().minute())
                        }
                    }
                    .chartYAxis {
                        AxisMarks(position: .leading)
                    }
                    .modifier(ChartNoteMarkersOverlay(notes: notesOnChart))
                    .frame(height: 220)
            }
        }
    }

    private var chartCore: some View {
        Chart {
            if let domain = xDomain {
                RectangleMark(
                    xStart: .value("rangeStart", domain.lowerBound),
                    xEnd: .value("rangeEnd", domain.upperBound),
                    yStart: .value("targetLow", Self.targetLowMmol),
                    yEnd: .value("targetHigh", Self.targetHighMmol)
                )
                .foregroundStyle(Color.green.opacity(0.14))
            }

            ForEach(history) { p in
                LineMark(
                    x: .value("Time", p.time),
                    y: .value("mmol/L", p.mmol)
                )
                .interpolationMethod(.catmullRom)
                .foregroundStyle(.blue)
            }
            ForEach(prediction) { p in
                LineMark(
                    x: .value("Time", p.time),
                    y: .value("Pred", p.mmol)
                )
                .interpolationMethod(.catmullRom)
                .foregroundStyle(.purple.opacity(0.65))
                .lineStyle(StrokeStyle(lineWidth: 1.5, dash: [4, 3]))
            }

            ForEach(notesOnChart) { note in
                if let t = note.timestamp {
                    RuleMark(x: .value("noteTime", t))
                        .foregroundStyle(Color.green.opacity(0.95))
                        .lineStyle(StrokeStyle(lineWidth: 1.5))
                }
            }
        }
    }
}

// MARK: - Carbs / insulin markers (overlay; iOS 17+)

private struct ChartNoteMarkersOverlay: ViewModifier {
    let notes: [BackendAPI.GlucoseNote]

    func body(content: Content) -> some View {
        if #available(iOS 17.0, *) {
            content.chartOverlay { proxy in
                GeometryReader { geometry in
                    let plotFrame = proxy.plotFrame.map { geometry[$0] } ?? .zero
                    ForEach(notes) { note in
                        if let t = note.timestamp,
                           let xInPlot = proxy.position(forX: t) {
                            let x = plotFrame.minX + xInPlot
                            ChartNoteMarkerView(note: note, x: x, plotTop: plotFrame.minY, plotBottom: plotFrame.maxY)
                        }
                    }
                }
            }
        } else {
            content
        }
    }
}

private struct ChartNoteMarkerView: View {
    let note: BackendAPI.GlucoseNote
    let x: CGFloat
    let plotTop: CGFloat
    let plotBottom: CGFloat

    private var insulinLabel: String {
        let u = note.insulin
        guard u > 0 else { return "" }
        if abs(u - round(u)) < 0.05 {
            return String(format: "%.0f", u)
        }
        return String(format: "%.1f", u)
    }

    var body: some View {
        ZStack {
            if note.carbs > 0 {
                Text(String(format: "%.0fg", note.carbs))
                    .font(.caption2.weight(.semibold))
                    .padding(.horizontal, 6)
                    .padding(.vertical, 3)
                    .background(
                        RoundedRectangle(cornerRadius: 4)
                            .fill(Color(red: 1, green: 0.92, blue: 0.35))
                    )
                    .overlay(alignment: .bottom) {
                        TrianglePointer()
                            .fill(Color(red: 1, green: 0.92, blue: 0.35))
                            .frame(width: 10, height: 5)
                            .offset(y: 4)
                    }
                    .position(x: x, y: plotTop + 18)
            }

            if note.insulin > 0 {
                VStack(spacing: 2) {
                    Text(insulinLabel)
                        .font(.caption2.weight(.bold))
                        .foregroundStyle(.primary)
                    RoundedRectangle(cornerRadius: 2)
                        .fill(Color.blue.opacity(0.4))
                        .frame(width: 7, height: 16)
                }
                .position(x: x, y: plotBottom - 18)
            }
        }
    }
}

/// Small downward triangle under the carb chip (Libre-style callout).
private struct TrianglePointer: Shape {
    func path(in rect: CGRect) -> Path {
        var p = Path()
        p.move(to: CGPoint(x: rect.midX, y: rect.maxY))
        p.addLine(to: CGPoint(x: rect.minX, y: rect.minY))
        p.addLine(to: CGPoint(x: rect.maxX, y: rect.minY))
        p.closeSubpath()
        return p
    }
}

// MARK: - AI insights

struct AIInsightsSheet: View {
    @Environment(\.dismiss) private var dismiss
    @State private var isLoading = false
    @State private var errorMessage: String?
    @State private var result: BackendAPI.AiAnalysisResult?

    var body: some View {
        NavigationStack {
            Group {
                if isLoading {
                    ProgressView("Analyzing last 12 hours...")
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else if let err = errorMessage {
                    Text(err)
                        .foregroundColor(.red)
                        .padding()
                } else if let r = result {
                    ScrollView {
                        VStack(alignment: .leading, spacing: 16) {
                            if let s = r.summary, !s.isEmpty {
                                Text(s)
                                    .font(.body)
                            }
                            if let recs = r.recommendations, !recs.isEmpty {
                                Text("Recommendations")
                                    .font(.headline)
                                ForEach(Array(recs.enumerated()), id: \.offset) { _, item in
                                    if let t = item.text, !t.isEmpty {
                                        Text("- \(t)")
                                            .font(.subheadline)
                                    }
                                }
                            }
                            if let d = r.disclaimer, !d.isEmpty {
                                Text(d)
                                    .font(.caption)
                                    .foregroundColor(.secondary)
                            }
                        }
                        .padding()
                    }
                } else {
                    Text("Run an analysis to see AI insights for your recent glucose and notes.")
                        .font(.subheadline)
                        .foregroundColor(.secondary)
                        .padding()
                }
            }
            .navigationTitle("AI insights")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Close") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Run") { Task { await run() } }
                    .disabled(isLoading)
                }
            }
            .task { await run() }
        }
    }

    private func run() async {
        isLoading = true
        errorMessage = nil
        defer { isLoading = false }
        do {
            result = try await BackendAPI.fetchAiRetrospective(windowHours: 12)
        } catch {
            errorMessage = error.localizedDescription
        }
    }
}

// MARK: - Nutrition

struct NutritionAnalyzerSheet: View {
    @Environment(\.dismiss) private var dismiss
    @State private var ingredients = ""
    @State private var fallbackCarbs = ""
    @State private var isLoading = false
    @State private var errorMessage: String?
    @State private var snapshot: BackendAPI.NutritionSnapshot?

    var body: some View {
        NavigationStack {
            Form {
                Section("Ingredients") {
                    TextField("Describe the meal or paste ingredients", text: $ingredients, axis: .vertical)
                        .lineLimit(3...8)
                    TextField("Fallback carbs (g), optional", text: $fallbackCarbs)
                        .keyboardType(.decimalPad)
                }
                if let snap = snapshot {
                    Section("Estimate") {
                        if let c = snap.totalCarbs {
                            LabeledContent("Carbs", value: String(format: "%.0f g", c))
                        }
                        if let g = snap.estimatedGi {
                            LabeledContent("Est. GI", value: String(format: "%.0f", g))
                        }
                        if let l = snap.glycemicLoad {
                            LabeledContent("GL", value: String(format: "%.1f", l))
                        }
                        if let cls = snap.absorptionSpeedClass {
                            LabeledContent("Absorption", value: cls)
                        }
                        if let foods = snap.normalizedFoods, !foods.isEmpty {
                            Text(foods.joined(separator: ", "))
                                .font(.caption)
                                .foregroundColor(.secondary)
                        }
                    }
                }
                if let err = errorMessage {
                    Section {
                        Text(err).foregroundColor(.red)
                    }
                }
            }
            .navigationTitle("Nutrition GI/GL")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Close") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Analyze") { Task { await analyze() } }
                    .disabled(isLoading || ingredients.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
            }
        }
    }

    private func analyze() async {
        isLoading = true
        errorMessage = nil
        defer { isLoading = false }
        let fb = Double(fallbackCarbs.trimmingCharacters(in: .whitespacesAndNewlines))
        let text = ingredients.trimmingCharacters(in: .whitespacesAndNewlines)
        do {
            snapshot = try await BackendAPI.analyzeNutrition(
                ingredientsText: text,
                fallbackCarbs: fb
            )
        } catch {
            errorMessage = error.localizedDescription
        }
    }
}

// MARK: - Version

struct VersionInfoSheet: View {
    @Environment(\.dismiss) private var dismiss
    @State private var version: BackendAPI.BackendVersionPayload?
    @State private var compatibility: BackendAPI.CompatibilityPayload?
    @State private var errorMessage: String?

    var body: some View {
        NavigationStack {
            Form {
                if let v = version {
                    Section("Backend") {
                        LabeledContent("Version", value: v.version ?? "--")
                        LabeledContent("API", value: v.apiVersion ?? "--")
                        LabeledContent("Environment", value: v.environment ?? "--")
                    }
                    if let minIos = v.minIosVersion {
                        Section("iOS compatibility") {
                            LabeledContent("Min iOS app", value: minIos)
                            if let list = v.compatibleIosVersions, !list.isEmpty {
                                Text(list.joined(separator: ", "))
                                    .font(.caption)
                                    .foregroundColor(.secondary)
                            }
                        }
                    }
                }
                if let c = compatibility {
                    Section("This app") {
                        LabeledContent("Client version", value: c.clientVersion ?? ClientVersion.resolvedSemanticVersion())
                        LabeledContent("Compatible", value: (c.compatible == true) ? "Yes" : "No")
                        LabeledContent("Meets minimum", value: (c.meetsMinimumVersion == true) ? "Yes" : "No")
                        if let r = c.recommendation, !r.isEmpty {
                            Text(r)
                                .font(.footnote)
                                .foregroundColor(.secondary)
                        }
                    }
                }
                if let err = errorMessage {
                    Section {
                        Text(err).foregroundColor(.red)
                    }
                }
            }
            .navigationTitle("Version")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
            }
            .task { await load() }
        }
    }

    private func load() async {
        errorMessage = nil
        do {
            async let v = BackendAPI.fetchBackendVersion()
            async let c = BackendAPI.checkCompatibility()
            version = try await v
            compatibility = try await c
        } catch {
            errorMessage = error.localizedDescription
        }
    }
}
