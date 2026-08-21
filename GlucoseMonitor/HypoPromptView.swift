import SwiftUI

/// Confirm sheet shown when the backend has detected glucose below the hypo threshold.
///
/// One tap logs a preset amount. During a hypo the user is cognitively impaired, so the
/// common path is deliberately a single tap with no typing.
struct HypoPromptView: View {

    let event: BackendAPI.HypoEvent
    let displayUnit: String
    let onConfirm: (Double) -> Void
    let onDismiss: () -> Void

    @State private var customGrams: String = ""

    private var displayedGlucose: String {
        let value = GlucoseUnit.fromMmol(event.triggerGlucoseMmol, displayUnit: displayUnit)
        return GlucoseUnit.isMgdl(displayUnit)
            ? String(format: "%.0f", value)
            : String(format: "%.1f", value)
    }

    var body: some View {
        VStack(spacing: 24) {
            Image(systemName: "exclamationmark.triangle.fill")
                .font(.system(size: 44))
                .foregroundStyle(.orange)

            VStack(spacing: 6) {
                Text("Low glucose")
                    .font(.title2.weight(.semibold))
                Text("\(displayedGlucose) \(displayUnit)")
                    .font(.system(size: 40, weight: .bold, design: .rounded))
                Text("Did you take fast-acting carbs?")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }

            HStack(spacing: 12) {
                ForEach(BackendAPI.RescueCarbPresets.options, id: \.self) { grams in
                    Button {
                        onConfirm(grams)
                    } label: {
                        VStack(spacing: 2) {
                            Text("\(Int(grams))").font(.title3.weight(.bold))
                            Text("g").font(.caption2)
                        }
                        .frame(maxWidth: .infinity, minHeight: 64)
                    }
                    .buttonStyle(.borderedProminent)
                }
            }

            HStack {
                TextField("Other amount", text: $customGrams)
                    .keyboardType(.decimalPad)
                    .textFieldStyle(.roundedBorder)
                Button("Log") {
                    if let grams = Double(customGrams), grams > 0, grams <= 100 {
                        onConfirm(grams)
                    }
                }
                .disabled(Double(customGrams).map { $0 <= 0 || $0 > 100 } ?? true)
            }

            Button("Not now", role: .cancel) { onDismiss() }
                .padding(.top, 4)
        }
        .padding(24)
        .presentationDetents([.medium])
    }
}
