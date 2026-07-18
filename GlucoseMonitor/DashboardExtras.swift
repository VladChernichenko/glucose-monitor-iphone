import Charts
import Photos
import SwiftUI
import UIKit

// MARK: - Chart model

struct GlucoseChartPoint: Identifiable, Equatable {
    let time: Date
    let mmol: Double
    var id: String { String(format: "%.3f_%.2f", time.timeIntervalSince1970, mmol) }
}

struct PredictionChartPoint: Identifiable, Equatable {
    let time: Date
    let mmol: Double
    /// Confidence-band edges [mmol/L]; nil when the backend emits no uncertainty band.
    var lower: Double? = nil
    var upper: Double? = nil
    var id: String { String(format: "p_%.3f", time.timeIntervalSince1970) }
}

/// Time window for dashboard glucose charts.
struct GlucoseChartWindow {
    let historyLookback: TimeInterval?
    let forecastHorizon: TimeInterval
    let fixedXDomain: Bool

    static let standard = GlucoseChartWindow(
        historyLookback: 2 * 3600,
        forecastHorizon: 4 * 3600,
        fixedXDomain: true
    )
    static let extended = GlucoseChartWindow(
        historyLookback: 4 * 3600,
        forecastHorizon: 8 * 3600,
        fixedXDomain: true
    )
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
        if elapsed >= 2 * 3600 { return (false, "--") }
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
    var window: GlucoseChartWindow = .standard
    /// Actual current sensor reading (raw, not smoothed). Used to anchor the prediction line so
    /// it starts from the same value the backend used, eliminating the step at "now".
    var currentGlucose: Double? = nil

    /// mmol/L band matching common target range (shown like Libre-style charts).
    private static let targetLowMmol: Double = 4
    private static let targetHighMmol: Double = 10

    private var filteredHistory: [GlucoseChartPoint] {
        guard let lookback = window.historyLookback else { return history }
        let cutoff = Date().addingTimeInterval(-lookback)
        return history.filter { $0.time >= cutoff }
    }

    /// Display history is the raw CGM data, unsmoothed (no averaging).
    /// The most-recent point is snapped to `currentGlucose` (the raw sensor reading) so the
    /// history ends at the same value the backend used as its prediction base, preventing any
    /// visual step at the solid/dashed boundary.
    private var displayHistory: [GlucoseChartPoint] {
        var raw = filteredHistory.sorted { $0.time < $1.time }
        if let cg = currentGlucose, !raw.isEmpty {
            let i = raw.count - 1
            raw[i] = GlucoseChartPoint(time: raw[i].time, mmol: cg)
        }
        return raw
    }

    /// History extended by the prediction anchor so the solid line runs continuously to "now".
    /// The bridge endpoint uses the raw current glucose (same value the backend started from)
    /// so the solid and dashed lines share the same y-value at the "now" boundary.
    private var bridgedHistory: [GlucoseChartPoint] {
        let base = displayHistory
        guard let anchor = futurePrediction.first else { return base }
        guard let last = base.last else { return base }
        if anchor.time <= last.time { return base }
        let bridgeMmol = currentGlucose ?? last.mmol
        return base + [GlucoseChartPoint(time: anchor.time, mmol: bridgeMmol)]
    }

    private var xDomain: ClosedRange<Date>? {
        let now = Date()
        if window.fixedXDomain, let lookback = window.historyLookback {
            let lower = now.addingTimeInterval(-lookback)
            let upper = now.addingTimeInterval(window.forecastHorizon)
            return lower...upper
        }
        let t1 = filteredHistory.map(\.time)
        let t2 = prediction.map(\.time)
        let all = t1 + t2
        guard let mn = all.min(), let mx = all.max(), mn <= mx else { return nil }
        if mn == mx {
            return mn.addingTimeInterval(-1800)...mx.addingTimeInterval(1800)
        }
        let cap = now.addingTimeInterval(window.forecastHorizon)
        return mn...(mx < cap ? mx : cap)
    }

    /// Prediction points starting exactly at "now", capped to forecast horizon.
    /// Drops past points, then prepends a synthetic anchor at Date() whose value
    /// matches the raw current sensor reading (same value the backend started from),
    /// eliminating the visual step caused by history smoothing vs. raw current glucose.
    private var futurePrediction: [PredictionChartPoint] {
        let now = Date()
        let cap = now.addingTimeInterval(window.forecastHorizon)
        let future = prediction.filter { $0.time > now && $0.time <= cap }
        guard !future.isEmpty else { return [] }
        let anchorMmol = currentGlucose ?? displayHistory.last?.mmol ?? future[0].mmol
        // Pinch the band to zero width at "now" so the confidence cone fans out from the current value.
        let anchor = PredictionChartPoint(time: now, mmol: anchorMmol,
                                          lower: anchorMmol, upper: anchorMmol)
        return [anchor] + future
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
            if filteredHistory.isEmpty && futurePrediction.isEmpty {
                Text("No chart data yet")
                    .font(.subheadline)
                    .foregroundColor(.secondary)
                    .frame(maxWidth: .infinity, minHeight: 160)
            } else {
                ZStack {
                    Group {
                        if let domain = xDomain {
                            chartCore.chartXScale(domain: domain)
                        } else {
                            chartCore
                        }
                    }
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
                }
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

            // Confidence band (digital-twin uncertainty) - a widening cone around the forecast.
            // Only the points that carry both edges contribute; the anchor pinches it shut at "now".
            ForEach(futurePrediction) { p in
                if let lo = p.lower, let hi = p.upper {
                    AreaMark(
                        x: .value("Time", p.time),
                        yStart: .value("Lower", lo),
                        yEnd: .value("Upper", hi)
                    )
                    .interpolationMethod(.monotone)
                    .foregroundStyle(Color.blue.opacity(0.12))
                }
            }

            ForEach(bridgedHistory) { p in
                LineMark(
                    x: .value("Time", p.time),
                    y: .value("mmol/L", p.mmol),
                    series: .value("Series", "history")
                )
                .interpolationMethod(.monotone)
                .foregroundStyle(.blue)
            }

            ForEach(futurePrediction) { p in
                LineMark(
                    x: .value("Time", p.time),
                    y: .value("Pred", p.mmol),
                    series: .value("Series", "prediction")
                )
                .interpolationMethod(.monotone)
                .foregroundStyle(Color.blue)
                .lineStyle(StrokeStyle(lineWidth: 2, dash: [5, 4]))
            }

            ForEach(notesOnChart) { note in
                if let t = note.timestamp {
                    RuleMark(x: .value("noteTime", t))
                        .foregroundStyle(Color.green.opacity(0.95))
                        .lineStyle(StrokeStyle(lineWidth: 1.5))
                }
            }

            // Manual glucose readings from notes (orange dots)
            ForEach(notesOnChart.filter { $0.glucoseValue != nil }) { note in
                if let t = note.timestamp, let gv = note.glucoseValue {
                    PointMark(
                        x: .value("Time", t),
                        y: .value("mmol/L", gv)
                    )
                    .symbolSize(80)
                    .foregroundStyle(Color.orange)
                    .annotation(position: .top, spacing: 4) {
                        Text(String(format: "%.1f", gv))
                            .font(.system(size: 9, weight: .semibold))
                            .foregroundStyle(Color.orange)
                    }
                }
            }

            // Vertical "now" line - black in light mode, white in dark mode
            RuleMark(x: .value("Now", Date()))
                .foregroundStyle(Color.primary.opacity(0.75))
                .lineStyle(StrokeStyle(lineWidth: 1.5, dash: [4, 3]))
        }
    }
}

// MARK: - Carbs / insulin markers (overlay; iOS 17+)

private struct ChartNoteMarkersOverlay: ViewModifier {
    let notes: [BackendAPI.GlucoseNote]

    /// Max pixel gap between two notes before their carb labels are rendered separately.
    private static let groupingThreshold: CGFloat = 32

    func body(content: Content) -> some View {
        if #available(iOS 17.0, *) {
            content.chartOverlay { proxy in
                GeometryReader { geometry in
                    let plotFrame = proxy.plotFrame.map { geometry[$0] } ?? .zero

                    // Resolve every note to its pixel x position inside the plot.
                    let positioned: [(note: BackendAPI.GlucoseNote, x: CGFloat)] = notes
                        .compactMap { note in
                            guard let t = note.timestamp,
                                  let xInPlot = proxy.position(forX: t) else { return nil }
                            return (note, plotFrame.minX + xInPlot)
                        }
                        .sorted { $0.x < $1.x }

                    // -- Carb labels: grouped & summed --------------------------
                    let carbItems = positioned.filter { $0.note.carbs > 0 }
                    let carbGroups = Self.groupByProximity(carbItems,
                                                          threshold: Self.groupingThreshold)
                    ForEach(Array(carbGroups.enumerated()), id: \.offset) { _, group in
                        let totalCarbs = group.map(\.note.carbs).reduce(0, +)
                        let centerX    = group.map(\.x).reduce(0, +) / CGFloat(group.count)
                        CarbGroupLabel(carbs: totalCarbs, x: centerX, y: plotFrame.minY + 18)
                    }

                    // -- Insulin bars: grouped & summed ------------------------
                    let insulinItems = positioned.filter { $0.note.insulin > 0 }
                    let insulinGroups = Self.groupByProximity(insulinItems,
                                                             threshold: Self.groupingThreshold)
                    ForEach(Array(insulinGroups.enumerated()), id: \.offset) { _, group in
                        let totalInsulin = group.map(\.note.insulin).reduce(0, +)
                        let centerX      = group.map(\.x).reduce(0, +) / CGFloat(group.count)
                        InsulinBarLabel(insulin: totalInsulin, x: centerX, y: plotFrame.maxY - 18)
                    }
                }
            }
        } else {
            content
        }
    }

    /// Greedy left-to-right grouping: a new group starts whenever the gap
    /// to the previous item exceeds `threshold` pixels.
    private static func groupByProximity(
        _ items: [(note: BackendAPI.GlucoseNote, x: CGFloat)],
        threshold: CGFloat
    ) -> [[(note: BackendAPI.GlucoseNote, x: CGFloat)]] {
        guard !items.isEmpty else { return [] }
        var groups: [[(note: BackendAPI.GlucoseNote, x: CGFloat)]] = []
        var current: [(note: BackendAPI.GlucoseNote, x: CGFloat)] = [items[0]]
        for item in items.dropFirst() {
            if item.x - current.last!.x <= threshold {
                current.append(item)
            } else {
                groups.append(current)
                current = [item]
            }
        }
        groups.append(current)
        return groups
    }
}

// Carb chip shown once per proximity group, displaying the summed value.
private struct CarbGroupLabel: View {
    let carbs: Double
    let x: CGFloat
    let y: CGFloat

    private var label: String {
        carbs.truncatingRemainder(dividingBy: 1) < 0.05
            ? String(format: "%.0fg", carbs)
            : String(format: "%.1fg", carbs)
    }

    var body: some View {
        Text(label)
            .font(.caption2.weight(.semibold))
            .foregroundStyle(.black)
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
            .position(x: x, y: y)
    }
}

// Insulin bar shown once per proximity group, displaying the summed value.
private struct InsulinBarLabel: View {
    let insulin: Double
    let x: CGFloat
    let y: CGFloat

    private var label: String {
        abs(insulin - round(insulin)) < 0.05
            ? String(format: "%.0f", insulin)
            : String(format: "%.1f", insulin)
    }

    var body: some View {
        VStack(spacing: 2) {
            Text(label)
                .font(.caption2.weight(.bold))
                .foregroundStyle(.primary)
            RoundedRectangle(cornerRadius: 2)
                .fill(Color.blue.opacity(0.4))
                .frame(width: 7, height: 16)
        }
        .position(x: x, y: y)
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

// MARK: - Lightweight markdown renderer

/// Renders a markdown string using SwiftUI primitives.
/// Supports: # / ## / ### headers, **bold**, *italic*, `code`, bullet lists (- / *), horizontal rules (---).
/// Inline bold/italic/code is handled via iOS 15 AttributedString markdown parsing.
struct MarkdownTextView: View {
    let text: String

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            ForEach(Array(lines.enumerated()), id: \.offset) { _, line in
                lineView(for: line)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var lines: [String] { text.components(separatedBy: "\n") }

    @ViewBuilder
    private func lineView(for line: String) -> some View {
        if line.hasPrefix("### ") {
            inlineText(String(line.dropFirst(4))).font(.title3.bold())
        } else if line.hasPrefix("## ") {
            inlineText(String(line.dropFirst(3))).font(.title2.bold())
        } else if line.hasPrefix("# ") {
            inlineText(String(line.dropFirst(2))).font(.title.bold())
        } else if line == "---" || line == "***" || line == "___" {
            Divider()
        } else if line.hasPrefix("- ") || line.hasPrefix("* ") {
            HStack(alignment: .top, spacing: 6) {
                Text("•").font(.body)
                inlineText(String(line.dropFirst(2))).font(.body)
            }
        } else if line.isEmpty {
            Spacer().frame(height: 4)
        } else {
            inlineText(line).font(.body)
        }
    }

    /// Parses inline markdown (bold, italic, code) via AttributedString.
    private func inlineText(_ raw: String) -> Text {
        if let attributed = try? AttributedString(markdown: raw) {
            return Text(attributed)
        }
        return Text(raw)
    }
}

// MARK: - AI insights

struct AIInsightsSheet: View {
    @Environment(\.dismiss) private var dismiss
    @State private var isStreaming = false
    @State private var streamedMarkdown = ""
    @State private var errorMessage: String?
    @State private var streamTask: Task<Void, Never>?
    @State private var selectedProvider: String = UserDefaults.standard.string(forKey: "ai_provider") ?? "auto"

    private let providerOptions: [(label: String, value: String)] = [
        ("Auto", "auto"),
        ("Qwen", "qwen"),
        ("Ollama", "ollama"),
    ]

    var body: some View {
        NavigationStack {
            Group {
                if isStreaming && streamedMarkdown.isEmpty {
                    ProgressView("Analyzing last 12 hours...")
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else if let err = errorMessage {
                    ScrollView {
                        Text(err)
                            .foregroundColor(.red)
                            .padding()
                    }
                } else if !streamedMarkdown.isEmpty {
                    ScrollView {
                        VStack(alignment: .leading, spacing: 0) {
                            MarkdownTextView(text: streamedMarkdown)
                                .textSelection(.enabled)
                            if isStreaming {
                                HStack(spacing: 4) {
                                    ProgressView()
                                        .scaleEffect(0.7)
                                    Text("Generating...")
                                        .font(.caption)
                                        .foregroundColor(.secondary)
                                }
                                .padding(.top, 8)
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
            .navigationBarTitleDisplayMode(.inline)
            .toolbar(content: { insightsToolbar })
            .task { startStream() }
            .onDisappear { streamTask?.cancel() }
        }
    }

    @ToolbarContentBuilder
    private var insightsToolbar: some ToolbarContent {
        ToolbarItem(placement: .cancellationAction) {
            Button("Close") {
                streamTask?.cancel()
                dismiss()
            }
        }
        ToolbarItem(placement: .principal) {
            Picker("", selection: $selectedProvider) {
                ForEach(providerOptions, id: \.value) { option in
                    Text(option.label).tag(option.value)
                }
            }
            .pickerStyle(.segmented)
            .frame(width: 210)
            .onChange(of: selectedProvider) { newValue in
                UserDefaults.standard.set(newValue, forKey: "ai_provider")
            }
        }
        ToolbarItem(placement: .confirmationAction) {
            Button("Run") { startStream() }
                .disabled(isStreaming)
        }
    }

    private func startStream() {
        streamTask?.cancel()
        streamedMarkdown = ""
        errorMessage = nil
        isStreaming = true

        let provider = selectedProvider
        streamTask = Task {
            do {
                try await BackendAPI.streamAiRetrospective(windowHours: 12, provider: provider) { token in
                    streamedMarkdown += token
                }
            } catch is CancellationError {
                // dismissed - no error message needed
            } catch {
                errorMessage = error.localizedDescription
            }
            isStreaming = false
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
            .dismissKeyboardOnInteraction()
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

// MARK: - Meal Camera

/// Wraps UIImagePickerController for camera capture.
/// On success the image is saved to the photo library and the sheet dismisses.
struct CameraSheet: UIViewControllerRepresentable {
    @Environment(\.dismiss) private var dismiss

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    func makeUIViewController(context: Context) -> UIImagePickerController {
        let picker = UIImagePickerController()
        picker.sourceType = .camera
        picker.cameraCaptureMode = .photo
        picker.delegate = context.coordinator
        return picker
    }

    func updateUIViewController(_ uiViewController: UIImagePickerController, context: Context) {}

    final class Coordinator: NSObject, UINavigationControllerDelegate, UIImagePickerControllerDelegate {
        let parent: CameraSheet
        init(_ parent: CameraSheet) { self.parent = parent }

        func imagePickerController(
            _ picker: UIImagePickerController,
            didFinishPickingMediaWithInfo info: [UIImagePickerController.InfoKey: Any]
        ) {
            if let image = info[.originalImage] as? UIImage {
                saveToPhotoLibrary(image)
            }
            parent.dismiss()
        }

        func imagePickerControllerDidCancel(_ picker: UIImagePickerController) {
            parent.dismiss()
        }
    }
}

private func saveToPhotoLibrary(_ image: UIImage) {
    PHPhotoLibrary.requestAuthorization(for: .addOnly) { status in
        guard status == .authorized || status == .limited else { return }
        PHPhotoLibrary.shared().performChanges {
            PHAssetChangeRequest.creationRequestForAsset(from: image)
        }
    }
}

// MARK: - Note photo capture

/// Camera sheet that delivers the captured image via a callback (for attaching to a note).
struct NotePhotoCaptureSheet: UIViewControllerRepresentable {
    @Environment(\.dismiss) private var dismiss
    let noteId: String
    let onCapture: (UIImage) async -> Void

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    func makeUIViewController(context: Context) -> UIImagePickerController {
        let picker = UIImagePickerController()
        picker.sourceType = .camera
        picker.cameraCaptureMode = .photo
        picker.delegate = context.coordinator
        return picker
    }

    func updateUIViewController(_ uiViewController: UIImagePickerController, context: Context) {}

    final class Coordinator: NSObject, UINavigationControllerDelegate, UIImagePickerControllerDelegate {
        let parent: NotePhotoCaptureSheet
        init(_ parent: NotePhotoCaptureSheet) { self.parent = parent }

        func imagePickerController(
            _ picker: UIImagePickerController,
            didFinishPickingMediaWithInfo info: [UIImagePickerController.InfoKey: Any]
        ) {
            if let image = info[.originalImage] as? UIImage {
                Task {
                    await parent.onCapture(image)
                }
            }
            parent.dismiss()
        }

        func imagePickerControllerDidCancel(_ picker: UIImagePickerController) {
            parent.dismiss()
        }
    }
}
