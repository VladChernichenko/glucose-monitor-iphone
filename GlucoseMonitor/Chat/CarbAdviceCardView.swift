import Charts
import SwiftUI

/// Red card for the pre-emptive fast-carbs advice (spec screen 7): headline, forecast low without carbs,
/// min with the advised grams, both curves, recheck time and the "Took" buttons.
struct CarbAdviceCardView: View {
    let advice: BackendAPI.CarbAdvice
    let unit: String
    let isBusy: Bool
    let onTook: (Int) -> Void

    @State private var showOther = false
    @State private var otherText = ""

    private var otherGrams: Int? {
        guard let g = Int(otherText.trimmingCharacters(in: .whitespaces)), (1...100).contains(g) else { return nil }
        return g
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(ChatFormatting.carbAdviceHeadline(advice, unit: unit))
                .font(.headline)
                .foregroundStyle(.red)
            Text("Low without carbs: \(ChatFormatting.glucose(mmol: advice.minWithout, unit: unit)) \(ChatFormatting.unitLabel(unit)) at \(ChatFormatting.clock(advice.minWithoutAt))")
                .font(.subheadline)
            if advice.state == .takeNow, let grams = advice.grams, let minWith = advice.minWith {
                Text("With \(grams) g: min \(ChatFormatting.glucose(mmol: minWith, unit: unit))")
                    .font(.subheadline)
            }
            chart
            Text("Recheck at \(ChatFormatting.clock(advice.recheckAt))")
                .font(.caption)
                .foregroundStyle(.secondary)
            if advice.state == .takeNow, let grams = advice.grams {
                actions(grams: grams)
            }
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.red.opacity(0.10), in: RoundedRectangle(cornerRadius: 14))
        .overlay(RoundedRectangle(cornerRadius: 14).stroke(Color.red.opacity(0.4), lineWidth: 1))
        .accessibilityElement(children: .contain)
    }

    private struct Sample: Identifiable { let id: Int; let time: Date; let value: Double }

    private func samples(_ points: [BackendAPI.PredictionPathPoint]?, until: Date) -> [Sample] {
        (points ?? []).enumerated().compactMap { i, p in
            guard let g = p.predictedGlucose, p.timestamp <= until else { return nil }
            return Sample(id: i, time: p.timestamp, value: GlucoseUnit.fromMmol(g, displayUnit: unit))
        }
    }

    @ViewBuilder
    private var chart: some View {
        // Clip to ~2 h; the curves are 4-8 h long.
        let start = advice.curveWithout.first?.timestamp ?? Date()
        let end = start.addingTimeInterval(2 * 3600)
        let without = samples(advice.curveWithout, until: end)
        let with = samples(advice.curveWith, until: end)
        if without.count >= 2 {
            Chart {
                ForEach(without) { s in
                    LineMark(x: .value("Time", s.time), y: .value("Glucose", s.value), series: .value("Curve", "without"))
                        .foregroundStyle(.red)
                        .lineStyle(StrokeStyle(lineWidth: 2, dash: [5, 3]))
                }
                ForEach(with) { s in
                    LineMark(x: .value("Time", s.time), y: .value("Glucose", s.value), series: .value("Curve", "with"))
                        .foregroundStyle(.green)
                        .lineStyle(StrokeStyle(lineWidth: 2))
                }
            }
            .chartYScale(domain: .automatic(includesZero: false))
            .frame(height: 90)
            .accessibilityLabel("Forecast with and without carbs")
        }
    }

    @ViewBuilder
    private func actions(grams: Int) -> some View {
        HStack(spacing: 10) {
            Button("Took \(grams) g") { onTook(grams) }
                .buttonStyle(.borderedProminent)
                .tint(.red)
            Button("Took other\u{2026}") { showOther.toggle() }
                .buttonStyle(.bordered)
        }
        .disabled(isBusy)
        if showOther {
            HStack(spacing: 8) {
                TextField("grams", text: $otherText)
                    .keyboardType(.numberPad)
                    .textFieldStyle(.roundedBorder)
                    .frame(maxWidth: 100)
                Text("g")
                Button("Send") {
                    if let g = otherGrams { onTook(g); otherText = ""; showOther = false }
                }
                .buttonStyle(.borderedProminent)
                .disabled(otherGrams == nil || isBusy)
            }
        }
    }
}
