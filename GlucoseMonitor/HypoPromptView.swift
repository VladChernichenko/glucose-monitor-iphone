import SwiftUI

/// Confirm sheet shown when the backend has detected glucose below the hypo threshold.
///
/// One tap logs a preset amount. During a hypo the user is cognitively impaired, so the
/// common path is deliberately a single tap with no typing.
struct HypoPromptView: View {

    let event: BackendAPI.HypoEvent
    let displayUnit: String
    /// Logs `grams` against this event. Returns `true` when the server accepted it.
    ///
    /// The result is load-bearing, not informational: the view holds every control disabled for
    /// the duration of the call, and only a truthful failure signal can hand them back.
    let onConfirm: (Double) async -> Bool
    let onDismiss: () -> Void

    @State private var customGrams: String = ""
    /// True for the duration of one in-flight confirm, and only that.
    ///
    /// Set before the request and cleared when it *fails*. Set, it closes the client-side half of
    /// the double-tap race: the backend's confirm endpoint is idempotent and replays the first
    /// winner's note on a second call for the same event, so a second, un-disabled tap would
    /// silently succeed while logging a different amount than the one actually recorded.
    ///
    /// Cleared on failure, it keeps a transient network error from bricking the prompt. Left set -
    /// as it was - every preset, the text field and "Log" stayed disabled forever while the banner
    /// read "Please try again", because `AppState` deliberately keeps `openHypoEvent` set on error
    /// so `.sheet(item:)` preserves view identity and this `@State` survives. The only live control
    /// was "Not now", which dismisses server-side and then suppresses new prompts. A patient who ate
    /// 15 g of dextrose would have had nothing recorded, COB and the prediction curve still showing
    /// a low, and the recovery flagged as unlogged food.
    ///
    /// Not cleared on success: the sheet is on its way out, and re-enabling the controls in the
    /// frames before it disappears would reopen the race it exists to close.
    @State private var isSubmitting = false

    private var displayedGlucose: String {
        let value = GlucoseUnit.fromMmol(event.triggerGlucoseMmol, displayUnit: displayUnit)
        return GlucoseUnit.isMgdl(displayUnit)
            ? String(format: "%.0f", value)
            : String(format: "%.1f", value)
    }

    private var customGramsIsValid: Bool {
        guard let grams = Double(customGrams) else { return false }
        return grams > 0 && grams <= 100
    }

    /// Claim the in-flight slot synchronously, then await. The guard is set on the main actor
    /// before the `Task` suspends, so a second tap in the same run loop already sees it.
    private func submit(_ grams: Double) {
        guard !isSubmitting else { return }
        isSubmitting = true
        Task {
            if await onConfirm(grams) == false {
                isSubmitting = false
            }
        }
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
                        submit(grams)
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
                    .opacity(isSubmitting ? 0.5 : 1.0)
                Button("Log") {
                    if let grams = Double(customGrams), customGramsIsValid {
                        submit(grams)
                    }
                }
                .disabled(isSubmitting || !customGramsIsValid)
                .opacity(isSubmitting ? 0.5 : 1.0)
            }

            // Disabled while a confirm is in flight. `AppState.dismissHypo` clears `openHypoEvent`
            // *before* awaiting, so a dismiss landing first would take the sheet away, leave the
            // confirm to return 409, and lose the carbs with no retry path left anywhere.
            Button("Not now", role: .cancel) { onDismiss() }
                .padding(.top, 4)
                .disabled(isSubmitting)
                .opacity(isSubmitting ? 0.5 : 1.0)
        }
        .padding(24)
        .presentationDetents([.medium])
    }
}
