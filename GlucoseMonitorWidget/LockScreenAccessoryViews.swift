import SwiftUI
import UIKit
import WidgetKit

// MARK: - Formatting

private let widgetGlucoseArrowCharacter = "\u{2192}"

private let mmolRangeLow: Double = 4.0
private let mmolRangeHigh: Double = 10.0

private func formatGlucoseValue(_ snapshot: LockScreenWidgetSnapshot) -> String {
    guard let v = snapshot.glucoseValue else { return "--" }
    if snapshot.glucoseUnit.lowercased().contains("mg") {
        return String(format: "%.0f", v)
    }
    return String(format: "%.1f", v)
}

private func formatNumberInDisplayUnit(_ value: Double, unit: String) -> String {
    unit.lowercased().contains("mg")
        ? String(format: "%.0f", value)
        : String(format: "%.1f", value)
}

private func twoHourPredictionArrowLabel(_ snapshot: LockScreenWidgetSnapshot) -> String? {
    guard let predMmol = snapshot.twoHourPredictionMmol else { return nil }
    let u = snapshot.glucoseUnit
    let cur: String
    if let g = snapshot.glucoseValue {
        cur = formatNumberInDisplayUnit(g, unit: u)
    } else {
        cur = "--"
    }
    let predDisplay = GlucoseUnit.fromMmol(predMmol, displayUnit: u)
    let pred = formatNumberInDisplayUnit(predDisplay, unit: u)
    return "\(cur) \(widgetGlucoseArrowCharacter) \(pred)"
}

private func glucoseHeadline(_ snapshot: LockScreenWidgetSnapshot) -> String {
    twoHourPredictionArrowLabel(snapshot) ?? formatGlucoseValue(snapshot)
}

private func formatDeltaDisplay(_ snapshot: LockScreenWidgetSnapshot) -> String {
    guard let d = snapshot.deltaValue else { return "" }
    if snapshot.glucoseUnit.lowercased().contains("mg") {
        return String(format: "%+.0f", d)
    }
    return String(format: "%+.1f", d)
}

/// Live count-up since the CGM reading (system animates on Home Screen without per-second timeline entries).
private struct WidgetReadingAgeLabel: View {
    let savedAt: Date
    var font: Font = .system(size: 11, weight: .medium, design: .rounded)
    var color: Color = .white.opacity(0.55)

    var body: some View {
        Text(savedAt, style: .timer)
            .font(font)
            .foregroundStyle(color)
            .monospacedDigit()
    }
}

private func segmentColorMmol(_ mmol: Double) -> Color {
    if mmol < mmolRangeLow { return Color(red: 0.95, green: 0.35, blue: 0.35) }
    if mmol > mmolRangeHigh { return Color(red: 1, green: 0.58, blue: 0) }
    return Color(red: 0.2, green: 0.78, blue: 0.36)
}

/// Like reference layout: first tick `2p`, then `3`, `4`, `5` (meridian only on first).
private func chartAxisLabelsGluroo(_ points: [LockScreenWidgetSnapshot.ChartPoint]) -> [String] {
    guard points.count >= 2, let t0 = points.first?.time, let t1 = points.last?.time else { return [] }
    let span = t1.timeIntervalSince(t0)
    guard span > 120 else { return [] }
    return (0..<4).map { i in
        let t = t0.addingTimeInterval(span * Double(i) / 3.0)
        let h = Calendar.current.component(.hour, from: t)
        let h12 = h % 12 == 0 ? 12 : h % 12
        if i == 0 {
            return h >= 12 ? "\(h12)p" : "\(h12)a"
        }
        return "\(h12)"
    }
}

// MARK: - Simple sparkline (non-rectangular families)

private let sparklineGreen = Color(red: 0.2, green: 0.85, blue: 0.35)

private struct GlucoseSparkline: View {
    let points: [LockScreenWidgetSnapshot.ChartPoint]

    var body: some View {
        GeometryReader { _ in
            if points.count < 2 {
                Rectangle().fill(Color.white.opacity(0.12))
            } else {
                let mmols = points.map(\.mmol)
                let minY = (mmols.min() ?? 4) - 0.3
                let maxY = (mmols.max() ?? 10) + 0.3
                let span = max(maxY - minY, 0.5)
                Canvas { ctx, size in
                    let w = size.width
                    let h = size.height
                    for i in 1..<points.count {
                        let p0 = points[i - 1]
                        let p1 = points[i]
                        let x0 = CGFloat(i - 1) / CGFloat(points.count - 1) * w
                        let x1 = CGFloat(i) / CGFloat(points.count - 1) * w
                        let y0 = h - CGFloat((p0.mmol - minY) / span) * h
                        let y1 = h - CGFloat((p1.mmol - minY) / span) * h
                        let mid = (p0.mmol + p1.mmol) / 2
                        var line = Path()
                        line.move(to: CGPoint(x: x0, y: y0))
                        line.addLine(to: CGPoint(x: x1, y: y1))
                        ctx.stroke(line, with: .color(segmentColorMmol(mid)), lineWidth: 2)
                    }
                }
            }
        }
    }
}

// MARK: - Gluroo-style chart (grid + range-colored line + time axis)

private struct GlurooStyleChart: View {
    let points: [LockScreenWidgetSnapshot.ChartPoint]
    var chartHeight: CGFloat = 42
    var axisFontSize: CGFloat = 8

    private let gridDashStyle = StrokeStyle(lineWidth: 1, lineCap: .round, dash: [3, 5])

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            GeometryReader { _ in
                if points.count < 2 {
                    Rectangle().fill(Color.black)
                } else {
                    let mmols = points.map(\.mmol)
                    let minY = (mmols.min() ?? 4) - 0.35
                    let maxY = (mmols.max() ?? 10) + 0.35
                    let span = max(maxY - minY, 0.5)
                    Canvas { ctx, size in
                        let w = size.width
                        let h = size.height
                        ctx.fill(Path(CGRect(origin: .zero, size: size)), with: .color(.black))
                        for g in 0..<5 {
                            let y = CGFloat(g) / 4 * h
                            var grid = Path()
                            grid.move(to: CGPoint(x: 0, y: y))
                            grid.addLine(to: CGPoint(x: w, y: y))
                            ctx.stroke(grid, with: .color(.white.opacity(0.14)), style: gridDashStyle)
                        }
                        for i in 1..<points.count {
                            let p0 = points[i - 1]
                            let p1 = points[i]
                            let x0 = CGFloat(i - 1) / CGFloat(points.count - 1) * w
                            let x1 = CGFloat(i) / CGFloat(points.count - 1) * w
                            let y0 = h - CGFloat((p0.mmol - minY) / span) * h
                            let y1 = h - CGFloat((p1.mmol - minY) / span) * h
                            let mid = (p0.mmol + p1.mmol) / 2
                            var line = Path()
                            line.move(to: CGPoint(x: x0, y: y0))
                            line.addLine(to: CGPoint(x: x1, y: y1))
                            ctx.stroke(line, with: .color(segmentColorMmol(mid)), lineWidth: 3)
                        }
                    }
                }
            }
            .frame(height: chartHeight)
            .clipShape(RoundedRectangle(cornerRadius: 4))

            axisRow
        }
    }

    private var axisRow: some View {
        let labels = chartAxisLabelsGluroo(points)
        return HStack(spacing: 0) {
            ForEach(Array(labels.enumerated()), id: \.offset) { i, s in
                Text(s)
                    .font(.system(size: axisFontSize, weight: .medium, design: .rounded))
                    .foregroundStyle(.white.opacity(0.5))
                if i < labels.count - 1 {
                    Spacer(minLength: 0)
                }
            }
        }
    }
}

// MARK: - Entry view

struct GlucoseLockWidgetEntryView: View {
    @Environment(\.widgetFamily) private var family
    var entry: GlucoseWidgetEntry

    private var snapshot: LockScreenWidgetSnapshot {
        entry.snapshot ?? .empty
    }

    /// System-style orange for primary glucose readout.
    private var glurooOrange: Color { Color(red: 1, green: 0.58, blue: 0) }
    /// Pale yellow fork/COB (reference sidebar).
    private var glurooCobColor: Color { Color(red: 0.96, green: 0.88, blue: 0.48) }
    /// Pale blue syringe/IOB.
    private var glurooIobColor: Color { Color(red: 0.58, green: 0.8, blue: 1) }
    private var glurooSidebarFill: Color { Color(red: 0.14, green: 0.14, blue: 0.15) }

    private var widgetBlack: Color { Color(uiColor: .black) }

    var body: some View {
        ZStack {
            widgetBlack
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            Group {
                switch family {
                case .accessoryRectangular:
                    rectangularGlurooLayout
                case .accessoryCircular:
                    circularLayout
                case .accessoryInline:
                    inlineLayout
                case .systemSmall:
                    homeSmallLayout
                case .systemMedium:
                    homeMediumLayout
                case .systemLarge, .systemExtraLarge:
                    homeLargeGlurooLayout
                default:
                    rectangularGlurooLayout
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(widgetBlack)
        .containerBackground(for: .widget) {
            widgetBlack
        }
        // Fill the system widget slot edge-to-edge (no safe-area inset band inside the slot).
        .ignoresSafeArea()
        // Without fullColor, Lock Screen often uses vibrant mode and washes out solid black.
        .environment(\.widgetRenderingMode, .fullColor)
    }

    // MARK: Lock Screen rectangular (Gluroo-style)

    private var rectangularGlurooLayout: some View {
        ZStack {
            Color.black
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            HStack(alignment: .top, spacing: 0) {
                glurooSidebar(compact: true)
                VStack(alignment: .leading, spacing: 6) {
                    glurooHeaderRow(compact: true)
                    GlurooStyleChart(points: snapshot.chartPointsMmol(), chartHeight: 44, axisFontSize: 8)
                }
                .padding(.leading, 4)
                .padding(.trailing, 4)
                .padding(.vertical, 6)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                .background(Color.black)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .compositingGroup()
    }

    private func glurooSidebar(compact: Bool) -> some View {
        let iconSize: CGFloat = compact ? 10 : 12
        let valueFont: Font = compact ? .system(size: 10, weight: .semibold) : .system(size: 12, weight: .semibold)
        return VStack(spacing: compact ? 6 : 10) {
            Text("V")
                .font(.system(size: compact ? 11 : 13, weight: .medium, design: .rounded))
                .foregroundStyle(.white.opacity(0.4))
            Spacer(minLength: 0)
            HStack(spacing: 4) {
                Image(systemName: "fork.knife")
                    .font(.system(size: iconSize - 1, weight: .medium))
                Text(cobText)
            }
            .font(valueFont)
            .foregroundStyle(glurooCobColor)
            HStack(spacing: 4) {
                Image(systemName: "syringe.fill")
                    .font(.system(size: iconSize - 1, weight: .medium))
                Text(iobShortText)
            }
            .font(valueFont)
            .foregroundStyle(glurooIobColor)
            Spacer(minLength: 0)
        }
        .padding(.vertical, compact ? 6 : 12)
        .padding(.horizontal, compact ? 6 : 9)
        .frame(width: compact ? 48 : 56)
        .frame(maxHeight: .infinity)
        .background(glurooSidebarFill)
    }

    private func glurooHeaderRow(compact: Bool) -> some View {
        let u = snapshot.glucoseUnit
        let curStr = snapshot.glucoseValue.map { formatNumberInDisplayUnit($0, unit: u) } ?? "--"
        let numberFont: Font = compact
            ? .system(size: 32, weight: .bold, design: .rounded)
            : .system(size: 42, weight: .bold, design: .rounded)
        let brandFont: Font = compact
            ? .system(size: 10, weight: .semibold, design: .default)
            : .system(size: 12, weight: .semibold, design: .default)
        let sideFont: Font = compact
            ? .system(size: 11, weight: .semibold, design: .rounded)
            : .system(size: 13, weight: .semibold, design: .rounded)
        let ageFont: Font = compact
            ? .system(size: 10, weight: .medium, design: .rounded)
            : .system(size: 12, weight: .medium, design: .rounded)

        let currentMmol: Double = {
            guard let v = snapshot.glucoseValue else { return 5.5 }
            return GlucoseUnit.toMmol(v, unit: u)
        }()
        let glucoseColor = segmentColorMmol(currentMmol)

        return HStack(alignment: .firstTextBaseline, spacing: 0) {
            Text("Glucose")
                .font(brandFont)
                .foregroundStyle(.white.opacity(0.72))
                .frame(width: compact ? 54 : 68, alignment: .leading)

            Group {
                if let predMmol = snapshot.twoHourPredictionMmol {
                    let predVal = GlucoseUnit.fromMmol(predMmol, displayUnit: u)
                    let predStr = formatNumberInDisplayUnit(predVal, unit: u)
                    HStack(alignment: .firstTextBaseline, spacing: compact ? 4 : 6) {
                        Text(curStr)
                            .lineLimit(1)
                            .minimumScaleFactor(0.35)
                        Text(widgetGlucoseArrowCharacter)
                        Text(predStr)
                            .lineLimit(1)
                            .minimumScaleFactor(0.35)
                    }
                    .font(numberFont)
                    .foregroundStyle(glucoseColor)
                } else {
                    Text(formatGlucoseValue(snapshot))
                        .font(numberFont)
                        .foregroundStyle(glucoseColor)
                        .lineLimit(1)
                        .minimumScaleFactor(0.35)
                }
            }
            .frame(maxWidth: .infinity)

            VStack(alignment: .trailing, spacing: 2) {
                if !formatDeltaDisplay(snapshot).isEmpty {
                    Text(formatDeltaDisplay(snapshot))
                        .font(sideFont)
                        .foregroundStyle(.white)
                }
                WidgetReadingAgeLabel(savedAt: snapshot.readingAgeStart, font: ageFont)
            }
            .fixedSize(horizontal: true, vertical: false)
        }
    }

    // MARK: Other lock / home layouts

    private var circularLayout: some View {
        VStack(spacing: 1) {
            Text(glucoseHeadline(snapshot))
                .font(.system(size: 14, weight: .bold, design: .rounded))
                .minimumScaleFactor(0.45)
                .foregroundStyle(.white)
                .lineLimit(2)
                .multilineTextAlignment(.center)
            GlucoseSparkline(points: snapshot.chartPointsMmol())
                .frame(height: 12)
                .clipShape(RoundedRectangle(cornerRadius: 2))
            VStack(spacing: 0) {
                Text(cobText)
                    .font(.system(size: 8, weight: .semibold))
                    .monospacedDigit()
                Text(iobText)
                    .font(.system(size: 8, weight: .semibold))
                    .monospacedDigit()
            }
            .foregroundStyle(.white.opacity(0.9))
            .minimumScaleFactor(0.5)
        }
    }

    private var inlineLayout: some View {
        HStack(spacing: 5) {
            Text(glucoseHeadline(snapshot))
                .font(.subheadline.weight(.bold))
            Text(cobText)
                .font(.footnote.weight(.semibold))
                .monospacedDigit()
                .foregroundStyle(.white.opacity(0.85))
            Text(iobText)
                .font(.footnote.weight(.semibold))
                .monospacedDigit()
                .foregroundStyle(.white.opacity(0.85))
        }
        .foregroundStyle(.white)
        .minimumScaleFactor(0.7)
        .lineLimit(1)
    }

    private var homeMediumLayout: some View {
        let u = snapshot.glucoseUnit
        let curMmol: Double = {
            guard let v = snapshot.glucoseValue else { return 5.5 }
            return GlucoseUnit.toMmol(v, unit: u)
        }()
        let curStr = snapshot.glucoseValue.map { formatNumberInDisplayUnit($0, unit: u) } ?? "--"
        let glucoseColor = segmentColorMmol(curMmol)

        return ZStack {
            Color.black.ignoresSafeArea()
            VStack(alignment: .leading, spacing: 0) {
                // ── Top row ──────────────────────────────────────────────
                HStack(alignment: .firstTextBaseline, spacing: 0) {
                    Text("Glucose Monitor")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(.white.opacity(0.7))

                    Spacer(minLength: 4)

                    // Glucose + arrow + pred
                    Group {
                        if let predMmol = snapshot.twoHourPredictionMmol {
                            let predVal = GlucoseUnit.fromMmol(predMmol, displayUnit: u)
                            HStack(alignment: .firstTextBaseline, spacing: 4) {
                                Text(curStr)
                                Text(widgetGlucoseArrowCharacter)
                                    .foregroundStyle(.white.opacity(0.6))
                                Text(formatNumberInDisplayUnit(predVal, unit: u))
                            }
                        } else {
                            Text(curStr)
                        }
                    }
                    .font(.system(size: 34, weight: .bold, design: .rounded))
                    .foregroundStyle(glucoseColor)
                    .lineLimit(1)
                    .minimumScaleFactor(0.6)

                    Spacer(minLength: 4)

                    WidgetReadingAgeLabel(
                        savedAt: snapshot.readingAgeStart,
                        font: .system(size: 11, weight: .medium, design: .rounded)
                    )
                }
                .padding(.horizontal, 10)
                .padding(.top, 8)
                .padding(.bottom, 6)

                // ── Chart ─────────────────────────────────────────────────
                GlurooStyleChart(
                    points: snapshot.chartPointsMmol(),
                    chartHeight: 52,
                    axisFontSize: 9
                )
                .padding(.horizontal, 10)
                .padding(.bottom, 8)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        }
        .compositingGroup()
    }

    private var homeLargeGlurooLayout: some View {
        ZStack {
            Color.black
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            HStack(alignment: .top, spacing: 0) {
                glurooSidebar(compact: false)
                VStack(alignment: .leading, spacing: 14) {
                    glurooHeaderRow(compact: false)
                    GlurooStyleChart(points: snapshot.chartPointsMmol(), chartHeight: 140, axisFontSize: 12)
                }
                .padding(.leading, 6)
                .padding(.trailing, 6)
                .padding(.vertical, 12)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                .background(Color.black)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .compositingGroup()
    }

    private var homeSmallLayout: some View {
        VStack(spacing: 6) {
            Text(glucoseHeadline(snapshot))
                .font(.system(size: 25, weight: .bold, design: .rounded))
                .foregroundStyle(.white)
                .minimumScaleFactor(0.48)
                .lineLimit(2)
                .multilineTextAlignment(.center)
            GlucoseSparkline(points: snapshot.chartPointsMmol())
                .frame(height: 34)
                .clipShape(RoundedRectangle(cornerRadius: 4))
            HStack {
                Text("COB \(cobText)")
                Spacer()
                Text("IOB \(iobText)")
            }
            .font(.caption2.weight(.semibold))
            .monospacedDigit()
            .foregroundStyle(.white)
        }
        .padding(8)
    }

    private var cobText: String {
        guard let g = snapshot.cobGrams else { return "--" }
        return String(format: "%.0fg", g)
    }

    private var iobText: String {
        guard let u = snapshot.iobUnits else { return "--" }
        return String(format: "%.2f", u)
    }

    private var iobShortText: String {
        guard let u = snapshot.iobUnits else { return "--" }
        return String(format: "%.1fu", u)
    }
}

// MARK: - Previews

#Preview(as: .accessoryRectangular) {
    GlucoseLockScreenWidget()
} timeline: {
    GlucoseWidgetEntry(date: .now, snapshot: .preview)
}

#Preview(as: .accessoryCircular) {
    GlucoseLockScreenWidget()
} timeline: {
    GlucoseWidgetEntry(date: .now, snapshot: .preview)
}

#Preview(as: .systemLarge) {
    GlucoseLockScreenWidget()
} timeline: {
    GlucoseWidgetEntry(date: .now, snapshot: .preview)
}
