import SwiftUI

/// Result reveal shown after completing an experiment.
struct ExperimentResultView: View {
    let result: ExperimentResult
    let onDone: () -> Void

    @EnvironmentObject private var appState: AppState

    var body: some View {
        ScrollView {
            VStack(spacing: 24) {
                successHeader
                resultHero
                explanationCard
                if let comparison = comparisonText { comparisonCard(comparison) }
                // Hourly ISF profile lives next to the ISF experiment that births it.
                if result.computedIsf != nil {
                    IsfMealWindowChart()
                }
                actionButtons
            }
            .padding()
            .padding(.bottom, 32)
        }
        .background(Color(.systemGroupedBackground))
        .onAppear { confirmLongActingDoseIfApplicable() }
    }

    // MARK: - Sections

    private var successHeader: some View {
        VStack(spacing: 8) {
            Image(systemName: result.isStable == false ? "exclamationmark.circle.fill" : "checkmark.circle.fill")
                .font(.system(size: 56))
                .foregroundStyle(headerColor)
                .modifier(BounceSymbolModifier())
            Text(headerTitle)
                .font(.title.bold())
            Text(headerSubtitle)
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
        }
        .padding(.top, 16)
        .padding(.horizontal)
    }

    private var resultHero: some View {
        VStack(spacing: 6) {
            Text(primaryValueLabel)
                .font(.caption)
                .foregroundStyle(.secondary)
                .textCase(.uppercase)

            Text(primaryValueText)
                .font(.system(size: 52, weight: .bold, design: .rounded))
                .foregroundStyle(.primary)

            Text(primaryValueUnit)
                .font(.title3)
                .foregroundStyle(.secondary)

            if result.savedToSettings {
                Label("Saved to your settings", systemImage: "checkmark.seal.fill")
                    .font(.subheadline)
                    .foregroundStyle(.green)
                    .padding(.top, 4)
            }
        }
        .frame(maxWidth: .infinity)
        .padding(24)
        .background(Color(.secondarySystemGroupedBackground))
        .clipShape(RoundedRectangle(cornerRadius: 20))
    }

    private var explanationCard: some View {
        VStack(alignment: .leading, spacing: 10) {
            Label("What This Means", systemImage: "info.circle.fill")
                .font(.subheadline.bold())
                .foregroundStyle(.blue)
            Text(result.explanation ?? "")
                .font(.subheadline)
        }
        .padding()
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color(.secondarySystemGroupedBackground))
        .clipShape(RoundedRectangle(cornerRadius: 14))
    }

    @ViewBuilder
    private func comparisonCard(_ text: String) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Label("Population Comparison", systemImage: "person.3.fill")
                .font(.subheadline.bold())
                .foregroundStyle(.purple)
            Text(text)
                .font(.subheadline)
                .foregroundStyle(.secondary)
        }
        .padding()
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color(.secondarySystemGroupedBackground))
        .clipShape(RoundedRectangle(cornerRadius: 14))
    }

    private var actionButtons: some View {
        VStack(spacing: 12) {
            Button(action: onDone) {
                Text("Done")
                    .frame(maxWidth: .infinity)
                    .padding()
                    .background(Color.accentColor)
                    .foregroundStyle(.white)
                    .font(.headline)
                    .clipShape(RoundedRectangle(cornerRadius: 14))
            }
        }
    }

    // MARK: - Computed

    private var headerColor: Color {
        if result.isStable == false { return .orange }
        return .green
    }

    private var headerTitle: String {
        if result.isStable == true  { return "Basal Rate Stable OK" }
        if result.isStable == false { return "Basal Needs Attention" }
        return "Experiment Complete"
    }

    private var headerSubtitle: String {
        if result.isStable == true  { return "You can now run ISF and Carb tests." }
        if result.isStable == false { return "Discuss basal adjustment with your care team first." }
        return "Your personal setting has been calculated."
    }

    private var primaryValueLabel: String {
        if result.computedIsf != nil        { return "Insulin Sensitivity Factor" }
        if result.computedCarbRatio != nil  { return "Carb Factor" }
        return "Max Glucose Drift"
    }

    private var primaryValueText: String {
        if let isf = result.computedIsf        { return String(format: "%.2f", isf) }
        if let cr  = result.computedCarbRatio  { return String(format: "%.2f", cr)  }
        if let exp = result.experiment {
            // Extract delta from resultNotes
            if let stable = result.isStable { return stable ? "Stable" : "Unstable" }
        }
        return "-"
    }

    private var primaryValueUnit: String {
        if result.computedIsf != nil       { return "mmol/L per unit" }
        if result.computedCarbRatio != nil { return "mmol/L per gram" }
        return ""
    }

    // MARK: - Long-acting dose confirmation

    /// When a Basal Rate Check completes stably, the current long-acting dose has been
    /// proven correct for this user. Persist it so the next "Log long-acting" dialog
    /// pre-fills with the experiment-confirmed value rather than an arbitrary default.
    private func confirmLongActingDoseIfApplicable() {
        guard result.isStable == true else { return }
        let longActing = appState.notes.filter { $0.isLongActing && $0.insulin > 0 }
        let sorted = longActing.sorted { ($0.timestamp ?? .distantPast) > ($1.timestamp ?? .distantPast) }
        guard let confirmedDose = sorted.first?.insulin else { return }
        UserDefaults.standard.set(confirmedDose, forKey: "lastLongActingDose")
    }

    private var comparisonText: String? {
        if let isf = result.computedIsf {
            let avg = 2.5
            let diff = isf - avg
            let dir = diff > 0.3 ? "higher" : diff < -0.3 ? "lower" : "close to"
            return "Population average ISF is ~\(avg) mmol/L/u. Your value is \(dir) average."
        }
        if let cr = result.computedCarbRatio {
            let avg = 0.22
            let diff = cr - avg
            let dir = diff > 0.03 ? "higher" : diff < -0.03 ? "lower" : "close to"
            return "Population average Carb Factor is ~\(avg) mmol/L/g. Your value is \(dir) average."
        }
        return nil
    }
}

private struct BounceSymbolModifier: ViewModifier {
    func body(content: Content) -> some View {
        if #available(iOS 17.0, *) {
            content.symbolEffect(.bounce, value: true)
        } else {
            content
        }
    }
}
