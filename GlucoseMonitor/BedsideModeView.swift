import SwiftUI
import UIKit

struct BedsideModeView: View {
    @EnvironmentObject var appState: AppState
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()

            TimelineView(.periodic(from: .now, by: 1)) { context in
                HStack(spacing: 0) {
                    clockPanel(date: context.date)
                    glucosePanel(date: context.date)
                }
            }

            VStack {
                HStack {
                    Spacer()
                    Button {
                        dismiss()
                    } label: {
                        Image(systemName: "xmark.circle.fill")
                            .font(.title2)
                            .foregroundStyle(.white.opacity(0.3))
                            .padding(20)
                    }
                }
                Spacer()
            }
        }
        .preferredColorScheme(.dark)
        .onAppear  { UIApplication.shared.isIdleTimerDisabled = true }
        .onDisappear { UIApplication.shared.isIdleTimerDisabled = false }
        .statusBarHidden(true)
    }

    // MARK: - Clock

    private func clockPanel(date: Date) -> some View {
        VStack(spacing: 4) {
            Text(date, format: .dateTime.hour().minute())
                .font(.system(size: 72, weight: .thin, design: .rounded))
                .foregroundStyle(.white)
                .monospacedDigit()
            Text(date, format: .dateTime.weekday(.wide).month().day())
                .font(.system(size: 16, weight: .light))
                .foregroundStyle(.white.opacity(0.5))
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    // MARK: - Glucose panel

    private func glucosePanel(date: Date) -> some View {
        let r = appState.currentReading
        let calc = appState.calculations
        let unit = appState.preferredGlucoseUnit

        let displayValue: Double? = r.flatMap { reading in
            guard let v = reading.value else { return nil }
            return convertGlucose(v, from: reading.unit, to: unit)
        }

        let predValue: Double? = calc?.predictionPath?.last?.predictedGlucose

        let cobStr = calc.map { String(format: "%.0fg", $0.activeCarbsOnBoard) } ?? "--"
        let iobStr = appState.displayedIOB.map { String(format: "%.2fu", $0) } ?? "--"

        return VStack(alignment: .leading, spacing: 8) {
            // Glucose headline
            HStack(alignment: .center, spacing: 6) {
                if let current = displayValue, let pred = predValue {
                    Text(formatGlucose(current, unit: unit))
                        .font(.system(size: 38, weight: .bold, design: .rounded))
                        .foregroundStyle(glucoseColor(current, unit: unit))
                    Text("→")
                        .font(.system(size: 22, weight: .light))
                        .foregroundStyle(.white.opacity(0.5))
                    Text(formatGlucose(pred, unit: unit))
                        .font(.system(size: 38, weight: .bold, design: .rounded))
                        .foregroundStyle(glucoseColor(pred, unit: unit))
                } else if let current = displayValue {
                    Text(formatGlucose(current, unit: unit))
                        .font(.system(size: 38, weight: .bold, design: .rounded))
                        .foregroundStyle(glucoseColor(current, unit: unit))
                    if let arrow = r?.trendArrow, !arrow.isEmpty, arrow != "?" {
                        Text(arrow)
                            .font(.system(size: 28))
                    }
                } else {
                    Text("--")
                        .font(.system(size: 38, weight: .thin, design: .rounded))
                        .foregroundStyle(.white.opacity(0.3))
                }
            }
            .lineLimit(1)
            .minimumScaleFactor(0.7)

            // Mini chart
            if !appState.glucoseHistory.isEmpty {
                MiniGlucoseSparkline(points: appState.glucoseHistory, unit: unit)
                    .frame(height: 60)
            }

            // COB / IOB
            HStack(spacing: 32) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("COB")
                        .font(.caption2).foregroundStyle(.white.opacity(0.4))
                    Text(cobStr)
                        .font(.system(size: 22, weight: .semibold, design: .rounded))
                        .foregroundStyle(.white)
                }
                VStack(alignment: .leading, spacing: 2) {
                    Text("IOB")
                        .font(.caption2).foregroundStyle(.white.opacity(0.4))
                    Text(iobStr)
                        .font(.system(size: 22, weight: .semibold, design: .rounded))
                        .foregroundStyle(.white)
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
        .padding(.leading, 24)
    }

    // MARK: - Helpers

    private func convertGlucose(_ value: Double, from: String?, to: String) -> Double {
        let fromUnit = from?.lowercased() ?? "mmol/l"
        if fromUnit.contains("mmol") && to.lowercased().contains("mg") {
            return value * 18.018
        } else if fromUnit.contains("mg") && to.lowercased().contains("mmol") {
            return value / 18.018
        }
        return value
    }

    private func formatGlucose(_ value: Double, unit: String) -> String {
        unit.lowercased().contains("mmol")
            ? String(format: "%.1f", value)
            : String(format: "%.0f", value)
    }

    private func glucoseColor(_ value: Double, unit: String) -> Color {
        let mgdl = unit.lowercased().contains("mmol") ? value * 18.018 : value
        switch mgdl {
        case ..<54: return .red
        case ..<70: return Color(red: 1, green: 0.6, blue: 0)
        case ...180: return Color(red: 0.2, green: 0.85, blue: 0.4)
        default: return Color(red: 1, green: 0.8, blue: 0)
        }
    }
}

// MARK: - Sparkline

private struct MiniGlucoseSparkline: View {
    let points: [GlucoseChartPoint]
    let unit: String

    var body: some View {
        GeometryReader { geo in
            let values = points.map { unit.lowercased().contains("mmol") ? $0.mmol : $0.mmol * 18.018 }
            let minV = (values.min() ?? 0) - 1
            let maxV = (values.max() ?? 1) + 1
            let range = max(maxV - minV, 1)
            let w = geo.size.width
            let h = geo.size.height
            let step = points.count > 1 ? w / CGFloat(points.count - 1) : w

            Path { path in
                for (i, v) in values.enumerated() {
                    let x = CGFloat(i) * step
                    let y = h - CGFloat((v - minV) / range) * h
                    i == 0 ? path.move(to: CGPoint(x: x, y: y)) : path.addLine(to: CGPoint(x: x, y: y))
                }
            }
            .stroke(Color(red: 0.2, green: 0.85, blue: 0.4), lineWidth: 2)
        }
    }
}
