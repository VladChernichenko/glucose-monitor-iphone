import SwiftUI
import Charts

/// Full detail screen showing predicted vs actual glucose deltas and the suggestion.
struct VerificationDetailView: View {
    @ObservedObject var vm: VerificationViewModel
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 20) {
                    if let s = vm.summary, s.suggestionReady {
                        suggestionHeader(s)
                        scatterChart
                        eventsTable
                        currentVsSuggested(s)
                        applyButton(s)
                    } else {
                        collectingDataView
                    }
                }
                .padding()
                .padding(.bottom, 32)
            }
            .background(Color(.systemGroupedBackground))
            .navigationTitle("Carb Ratio Refinement")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Close") { dismiss() }
                }
            }
        }
    }

    // MARK: - Sections

    @ViewBuilder
    private func suggestionHeader(_ s: VerificationSummary) -> some View {
        VStack(spacing: 8) {
            Image(systemName: "chart.line.uptrend.xyaxis.circle.fill")
                .font(.system(size: 44))
                .foregroundStyle(.orange)
            Text("Your settings can be refined")
                .font(.title3.bold())
            Text("Based on \(s.nEvents) real meals, your predicted glucose consistently differs from actual.")
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
        }
        .padding()
        .frame(maxWidth: .infinity)
        .background(Color(.secondarySystemGroupedBackground))
        .clipShape(RoundedRectangle(cornerRadius: 16))
    }

    @ViewBuilder
    private var scatterChart: some View {
        let completed = vm.completedEvents.filter { $0.predictedDelta != nil && $0.actualDelta != nil }
        if !completed.isEmpty {
            VStack(alignment: .leading, spacing: 8) {
                Label("Predicted vs Actual", systemImage: "chart.dots.scatter")
                    .font(.subheadline.bold())

                if #available(iOS 16.0, *) {
                    Chart {
                        // Perfect-accuracy diagonal
                        let range: [Double] = [-4, -2, 0, 2, 4, 6]
                        ForEach(range, id: \.self) { v in
                            LineMark(x: .value("Predicted", v), y: .value("Actual", v))
                                .foregroundStyle(.gray.opacity(0.4))
                                .lineStyle(StrokeStyle(dash: [4, 4]))
                        }
                        ForEach(completed.prefix(20), id: \.stable_id) { ev in
                            PointMark(
                                x: .value("Predicted", ev.predictedDelta ?? 0),
                                y: .value("Actual",    ev.actualDelta    ?? 0)
                            )
                            .foregroundStyle(Color.accentColor)
                            .symbolSize(80)
                        }
                    }
                    .chartXAxisLabel("Predicted Δ (mmol/L)")
                    .chartYAxisLabel("Actual Δ (mmol/L)")
                    .frame(height: 200)
                } else {
                    Text("Chart requires iOS 16+")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            .padding()
            .background(Color(.secondarySystemGroupedBackground))
            .clipShape(RoundedRectangle(cornerRadius: 14))
        }
    }

    @ViewBuilder
    private var eventsTable: some View {
        let completed = vm.completedEvents.prefix(7)
        if !completed.isEmpty {
            VStack(alignment: .leading, spacing: 8) {
                Label("Meal Analysis", systemImage: "list.bullet")
                    .font(.subheadline.bold())

                HStack {
                    Text("Date").font(.caption2).foregroundStyle(.secondary)
                    Spacer()
                    Text("Pred").font(.caption2).foregroundStyle(.secondary).frame(width: 52, alignment: .trailing)
                    Text("Actual").font(.caption2).foregroundStyle(.secondary).frame(width: 52, alignment: .trailing)
                    Text("Error").font(.caption2).foregroundStyle(.secondary).frame(width: 52, alignment: .trailing)
                }
                .padding(.horizontal, 4)

                ForEach(completed, id: \.stable_id) { ev in
                    HStack {
                        Text(shortDate(ev.createdAt ?? ""))
                            .font(.caption.monospacedDigit())
                            .foregroundStyle(.secondary)
                        Spacer()
                        Text(format(ev.predictedDelta)).frame(width: 52, alignment: .trailing)
                        Text(format(ev.actualDelta)).frame(width: 52, alignment: .trailing)
                        Text(format(ev.error))
                            .frame(width: 52, alignment: .trailing)
                            .foregroundStyle(errorColor(ev.error))
                    }
                    .font(.caption.monospacedDigit())
                    Divider()
                }
            }
            .padding()
            .background(Color(.secondarySystemGroupedBackground))
            .clipShape(RoundedRectangle(cornerRadius: 14))
        }
    }

    @ViewBuilder
    private func currentVsSuggested(_ s: VerificationSummary) -> some View {
        VStack(spacing: 12) {
            if let cr = s.suggestedCarbRatio {
                settingRow(label: "Carb Factor",
                           unit: "mmol/L / g",
                           current: nil,
                           suggested: cr,
                           confidence: s.confidence ?? "")
            }
            if let isf = s.suggestedIsf {
                settingRow(label: "ISF",
                           unit: "mmol/L / u",
                           current: nil,
                           suggested: isf,
                           confidence: s.confidence ?? "")
            }
        }
    }

    @ViewBuilder
    private func settingRow(label: String, unit: String, current: Double?,
                             suggested: Double, confidence: String) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(label).font(.subheadline.bold())
            HStack {
                if let cur = current {
                    VStack(alignment: .leading) {
                        Text("Current").font(.caption).foregroundStyle(.secondary)
                        Text(String(format: "%.2f", cur)).font(.title3.bold())
                    }
                    Image(systemName: "arrow.right").foregroundStyle(.secondary)
                }
                VStack(alignment: .leading) {
                    Text("Suggested").font(.caption).foregroundStyle(.secondary)
                    Text(String(format: "%.2f", suggested)).font(.title3.bold()).foregroundStyle(.orange)
                }
                Spacer()
                Text(unit).font(.caption).foregroundStyle(.secondary)
            }
            confidenceRow(confidence)
        }
        .padding()
        .background(Color(.secondarySystemGroupedBackground))
        .clipShape(RoundedRectangle(cornerRadius: 14))
    }

    @ViewBuilder
    private func confidenceRow(_ confidence: String) -> some View {
        let (color, label): (Color, String) = {
            switch confidence {
            case "HIGH":   return (.green,  "High confidence — 7+ consistent meals")
            case "MEDIUM": return (.orange, "Medium confidence — 4–6 meals")
            default:       return (.red,    "Low confidence — collecting more data")
            }
        }()
        HStack(spacing: 6) {
            Circle().fill(color).frame(width: 8, height: 8)
            Text(label).font(.caption).foregroundStyle(color)
        }
    }

    @ViewBuilder
    private func applyButton(_ s: VerificationSummary) -> some View {
        VStack(spacing: 12) {
            Button {
                Task {
                    await vm.acceptSuggestion()
                    if vm.accepted { dismiss() }
                }
            } label: {
                HStack {
                    if vm.isAccepting {
                        ProgressView().tint(.white)
                    } else {
                        Image(systemName: "checkmark.circle.fill")
                        Text("Apply Suggested Value")
                    }
                }
                .frame(maxWidth: .infinity)
                .padding()
                .background(Color.orange)
                .foregroundStyle(.white)
                .font(.headline)
                .clipShape(RoundedRectangle(cornerRadius: 14))
            }
            .disabled(vm.isAccepting)

            Button("Keep Current") { dismiss() }
                .font(.subheadline)
                .foregroundStyle(.secondary)
        }
    }

    @ViewBuilder
    private var collectingDataView: some View {
        VStack(spacing: 12) {
            Image(systemName: "hourglass")
                .font(.system(size: 44))
                .foregroundStyle(.secondary)
            Text("Collecting Data")
                .font(.title3.bold())
            if let n = vm.summary?.nEvents {
                Text("Analysed \(n) of 7 eligible meals.")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }
            Text("We need at least 7 consistent meals before making a suggestion. Eligible meals are simple fast/medium GI with both carbs and insulin.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
        }
        .padding()
        .frame(maxWidth: .infinity)
        .background(Color(.secondarySystemGroupedBackground))
        .clipShape(RoundedRectangle(cornerRadius: 16))
    }

    // MARK: - Helpers

    private func format(_ v: Double?) -> String {
        guard let v else { return "—" }
        return String(format: "%+.1f", v)
    }

    private func errorColor(_ v: Double?) -> Color {
        guard let v else { return .secondary }
        if abs(v) < 0.3 { return .green }
        if abs(v) < 0.7 { return .orange }
        return .red
    }

    private func shortDate(_ iso: String) -> String {
        let f = ISO8601DateFormatter()
        if let d = f.date(from: iso) {
            let out = DateFormatter(); out.dateFormat = "d MMM"
            return out.string(from: d)
        }
        return String(iso.prefix(10))
    }
}
