import SwiftUI

/// Wording for the prompt and detail views. Never dosing advice.
enum GlycemicEventCopy {
    static func question(for event: BackendAPI.GlycemicEvent) -> String {
        if event.isProvisional {
            return event.isRise
                ? "Your glucose held up although insulin was active. What's going on?"
                : "Your glucose dropped more than expected. What happened?"
        }
        return "Does this look right?"
    }

    /// e.g. "3.0 mmol/L above the forecast for 70 min".
    static func summary(for event: BackendAPI.GlycemicEvent, displayUnit: String) -> String {
        let magnitude = GlucoseUnit.fromMmol(abs(event.meanResidualMmol), displayUnit: displayUnit)
        let value = displayUnit == "mg/dL" ? String(format: "%.0f", magnitude) : String(format: "%.1f", magnitude)
        let minutes = Int((event.windowEnd.timeIntervalSince(event.onsetAt) / 60).rounded())
        return "\(value) \(displayUnit) \(event.isRise ? "above" : "below") the forecast for \(minutes) min"
    }
}

enum GlycemicAmount {
    static let carbPresets: [Double] = [10, 20, 30]
    static let insulinPresets: [Double] = [1, 2, 4]

    /// A positive amount, accepting a comma decimal separator; nil for empty or invalid input.
    static func parse(_ text: String) -> Double? {
        let cleaned = text.trimmingCharacters(in: .whitespaces).replacingOccurrences(of: ",", with: ".")
        guard let v = Double(cleaned), v > 0 else { return nil }
        return v
    }
}

/// The one-tap answer row, shared by the chat prompt bubble and the detail sheet. Food and insulin answers
/// expand an optional amount (presets or typed); every other answer confirms immediately.
struct GlycemicAnswerButtons: View {
    let options: [String]
    let isBusy: Bool
    let onAnswer: (_ category: String, _ carbs: Double?, _ insulin: Double?) -> Void

    @State private var amountFor: String?
    @State private var amountText = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            FlowRow(spacing: 6) {
                ForEach(options, id: \.self) { option in
                    Button(GlycemicCategory.buttonTitle(option)) {
                        if GlycemicCategory.takesCarbs(option) || GlycemicCategory.takesInsulin(option) {
                            amountFor = option
                        } else {
                            onAnswer(option, nil, nil)
                        }
                    }
                    .buttonStyle(.bordered)
                }
            }
            if let category = amountFor {
                let isCarbs = GlycemicCategory.takesCarbs(category)
                HStack(spacing: 6) {
                    ForEach(isCarbs ? GlycemicAmount.carbPresets : GlycemicAmount.insulinPresets, id: \.self) { preset in
                        Button(isCarbs ? "\(Int(preset)) g" : "\(Int(preset)) u") {
                            submit(category, amount: preset)
                        }
                        .buttonStyle(.bordered)
                    }
                    TextField(isCarbs ? "g" : "u", text: $amountText)
                        .keyboardType(.decimalPad)
                        .textFieldStyle(.roundedBorder)
                        .frame(width: 64)
                    Button("Save") { submit(category, amount: GlycemicAmount.parse(amountText)) }
                        .disabled(GlycemicAmount.parse(amountText) == nil)
                    Button("Skip amount") { submit(category, amount: nil) }
                        .font(.footnote)
                }
            }
        }
        .disabled(isBusy)
    }

    private func submit(_ category: String, amount: Double?) {
        let carbs = GlycemicCategory.takesCarbs(category) ? amount : nil
        let insulin = GlycemicCategory.takesInsulin(category) ? amount : nil
        amountFor = nil
        amountText = ""
        onAnswer(category, carbs, insulin)
    }
}

/// Minimal wrapping row for the answer buttons.
struct FlowRow: Layout {
    var spacing: CGFloat = 6

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let width = proposal.width ?? .infinity
        var x: CGFloat = 0, y: CGFloat = 0, rowHeight: CGFloat = 0
        for s in subviews {
            let size = s.sizeThatFits(.unspecified)
            if x > 0 && x + size.width > width { x = 0; y += rowHeight + spacing; rowHeight = 0 }
            x += size.width + spacing
            rowHeight = max(rowHeight, size.height)
        }
        return CGSize(width: width == .infinity ? x : width, height: y + rowHeight)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        var x = bounds.minX, y = bounds.minY, rowHeight: CGFloat = 0
        for s in subviews {
            let size = s.sizeThatFits(.unspecified)
            if x > bounds.minX && x + size.width > bounds.maxX { x = bounds.minX; y += rowHeight + spacing; rowHeight = 0 }
            s.place(at: CGPoint(x: x, y: y), proposal: ProposedViewSize(size))
            x += size.width + spacing
            rowHeight = max(rowHeight, size.height)
        }
    }
}
