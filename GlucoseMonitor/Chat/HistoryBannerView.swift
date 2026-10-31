import Charts
import SwiftUI

/// "Your past similar meals needed more" (spec screens 5 and 6): model dose against history dose with both
/// curves, nothing preselected. Choosing a dose re-checks it for lows: RED asks for a second tap, AMBER
/// shows a keep-carbs note, a refusal keeps the dose unknown.
struct HistoryBannerView: View {
    let banner: BackendAPI.HistoryBanner
    let state: HistoryBannerState
    let unit: String
    let isBusy: Bool
    let onChoose: (Double) -> Void
    let onConfirmRed: () -> Void
    let onBack: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(HistoryBannerRules.headline(banner)).font(.subheadline.weight(.bold)).foregroundStyle(Color.orange)
            Text(HistoryBannerRules.comparisonLine(banner)).font(.subheadline.weight(.semibold))
            if let line = HistoryBannerRules.episodesLine(banner, unit: unit) {
                Text(line).font(.caption).foregroundStyle(.secondary)
            }
            if let note = banner.pendingIsfNote {
                Text(note).font(.caption).foregroundStyle(.secondary)
            }
            curves
            answer
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.orange.opacity(0.10), in: RoundedRectangle(cornerRadius: 10))
        .overlay(RoundedRectangle(cornerRadius: 10).stroke(Color.orange.opacity(0.5), lineWidth: 1))
        .accessibilityElement(children: .contain)
    }

    // MARK: Answer

    @ViewBuilder
    private var answer: some View {
        switch state {
        case .unanswered(let notice):
            if let notice { noticeText(notice) }
            choiceButtons(disabled: isBusy)
        case .checking(let units):
            HStack(spacing: 8) {
                ProgressView()
                Text("Checking \(MealPlanRules.doseText(units)) for lows\u{2026}").font(.caption)
            }
        case .answered(let units, let recheck, let confirmed):
            answered(units: units, recheck: recheck, confirmed: confirmed)
        }
    }

    private func choiceButtons(disabled: Bool) -> some View {
        HStack(spacing: 8) {
            Button("Use \(MealPlanRules.doseText(banner.historyUnits))") { onChoose(banner.historyUnits) }
                .buttonStyle(.bordered)
            Button("Keep \(MealPlanRules.doseText(banner.modelUnits))") { onChoose(banner.modelUnits) }
                .buttonStyle(.bordered)
        }
        .disabled(disabled)
    }

    private func noticeText(_ text: String) -> some View {
        Text(text).font(.footnote).foregroundStyle(Color.red)
    }

    @ViewBuilder
    private func answered(units: Double, recheck: BackendAPI.DoseRecheck, confirmed: Bool) -> some View {
        let dose = MealPlanRules.doseText(units)
        let lowest = HistoryBannerRules.lowestText(recheck, unit: unit)
        switch HistoryBannerRules.level(recheck) {
        case .red:
            VStack(alignment: .leading, spacing: 6) {
                Text("\(dose) may take you low").font(.subheadline.weight(.bold)).foregroundStyle(Color.red)
                Text(lowest.map { "Forecast lowest \($0) \(ChatFormatting.unitLabel(unit))." } ?? "The forecast goes below your low limit.")
                    .font(.footnote)
                if confirmed {
                    Text("Using \(dose) anyway.").font(.footnote.weight(.semibold))
                    Button("Back", action: onBack).buttonStyle(.bordered).disabled(isBusy)
                } else {
                    HStack(spacing: 8) {
                        Button("Use \(dose) anyway", action: onConfirmRed)
                            .buttonStyle(.borderedProminent).tint(.red)
                        Button(backLabel(units), action: backAction(units)).buttonStyle(.bordered)
                    }
                    .disabled(isBusy)
                }
            }
            .padding(8)
            .background(Color.red.opacity(0.10), in: RoundedRectangle(cornerRadius: 8))
            .overlay(RoundedRectangle(cornerRadius: 8).stroke(Color.red.opacity(0.5), lineWidth: 1))
        case .amber:
            VStack(alignment: .leading, spacing: 6) {
                Text("Lowest \(lowest ?? "--") with \(dose). Keep ~10 g carbs handy.").font(.footnote.weight(.semibold))
                Button("Back", action: onBack).buttonStyle(.bordered).disabled(isBusy)
            }
            .padding(8)
            .background(Color.orange.opacity(0.14), in: RoundedRectangle(cornerRadius: 8))
        case .ok:
            HStack {
                Label("\(dose) checked", systemImage: "checkmark.circle").font(.footnote.weight(.semibold))
                Spacer()
                Button("Back", action: onBack).buttonStyle(.bordered).disabled(isBusy)
            }
        case nil:
            choiceButtons(disabled: isBusy)
        }
    }

    /// RED: "Back to 4 U" re-checks the model dose; when the red dose already is the model dose, just back.
    private func backLabel(_ units: Double) -> String {
        units == banner.modelUnits ? "Back" : "Back to \(MealPlanRules.doseText(banner.modelUnits))"
    }

    private func backAction(_ units: Double) -> () -> Void {
        units == banner.modelUnits ? onBack : { onChoose(banner.modelUnits) }
    }

    // MARK: Curves

    private struct Sample: Identifiable { let id: Int; let time: Date; let value: Double }

    private func samples(_ curve: [BackendAPI.PredictionPathPoint]) -> [Sample] {
        curve.enumerated().compactMap { i, p in
            p.predictedGlucose.map { Sample(id: i, time: p.timestamp, value: GlucoseUnit.fromMmol($0, displayUnit: unit)) }
        }
    }

    @ViewBuilder
    private var curves: some View {
        let model = samples(banner.modelCurve), history = samples(banner.historyCurve)
        if model.count >= 2 || history.count >= 2 {
            Chart {
                RectangleMark(yStart: .value("Low", GlucoseUnit.fromMmol(3.9, displayUnit: unit)),
                              yEnd: .value("High", GlucoseUnit.fromMmol(10, displayUnit: unit)))
                    .foregroundStyle(Color.green.opacity(0.10))
                ForEach(model) { s in
                    LineMark(x: .value("Time", s.time), y: .value("Model", s.value), series: .value("Dose", "model"))
                        .foregroundStyle(Color.blue)
                }
                ForEach(history) { s in
                    LineMark(x: .value("Time", s.time), y: .value("History", s.value), series: .value("Dose", "history"))
                        .foregroundStyle(Color.orange)
                        .lineStyle(StrokeStyle(lineWidth: 2, dash: [4, 3]))
                }
            }
            .chartYScale(domain: .automatic(includesZero: false))
            .frame(height: 100)
            .accessibilityLabel("Forecast with the model dose and with the history dose")
            Text(legend).font(.caption).foregroundStyle(.secondary)
        }
    }

    private var legend: String {
        func part(_ name: String, _ units: Double, _ peak: Double?, _ low: Double?) -> String {
            var t = "\(name) \(MealPlanRules.doseText(units)): "
            var bits: [String] = []
            if let peak { bits.append("peak \(ChatFormatting.glucose(mmol: peak, unit: unit))") }
            if let low { bits.append("lowest \(ChatFormatting.glucose(mmol: low, unit: unit))") }
            t += bits.isEmpty ? "--" : bits.joined(separator: ", ")
            return t
        }
        return "Blue " + part("model", banner.modelUnits, banner.modelPeak, banner.modelMin)
            + " \u{00B7} Orange " + part("history", banner.historyUnits, banner.historyPeak, banner.historyMin)
    }
}
