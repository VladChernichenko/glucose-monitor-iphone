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
    /// Set on the first tap of any preset or "Log", and never cleared while the sheet is up.
    /// Closes the client-side half of the double-tap race: the backend's confirm endpoint is
    /// idempotent and replays the first winner's note on a second call for the same event, so a
    /// second, un-disabled tap would silently succeed while logging a different amount than the
    /// one actually recorded. Disabling every submit control after the first tap means only one
    /// `onConfirm` can ever fire per prompt.
    @State private var isSubmitting = false

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
                        isSubmitting = true
                        onConfirm(grams)
                    } label: {
                        VStack(spacing: 2) {
                            Text("\(Int(grams))").font(.title3.weight(.bold))
                            Text("g").font(.caption2)
                        }
                        .frame(maxWidth: .infinity, minHeight: 64)
                    }
                    .buttonStyle(.borderedProminent)
                    .disabled(isSubmitting)
                    .opacity(isSubmitting ? 0.5 : 1.0)
                }
            }

            HStack {
                TextField("Other amount", text: $customGrams)
                    .keyboardType(.decimalPad)
                    .textFieldStyle(.roundedBorder)
                    .disabled(isSubmitting)
                Button("Log") {
                    if let grams = Double(customGrams), grams > 0, grams <= 100 {
                        isSubmitting = true
                        onConfirm(grams)
                    }
                }
                .disabled(isSubmitting || Double(customGrams).map { $0 <= 0 || $0 > 100 } ?? true)
                .opacity(isSubmitting ? 0.5 : 1.0)
            }

            Button("Not now", role: .cancel) { onDismiss() }
                .padding(.top, 4)
        }
        .padding(24)
        .presentationDetents([.medium])
    }
}
