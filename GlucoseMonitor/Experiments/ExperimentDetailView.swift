import SwiftUI

/// Full-screen explanation and onboarding before starting an experiment.
struct ExperimentDetailView: View {
    let experiment: AvailableExperiment
    @ObservedObject var viewModel: ExperimentViewModel

    @Environment(\.dismiss) private var dismiss
    @State private var gramsInput: String = "15"
    @State private var unitsInput: String = "1.0"
    @State private var isStarting = false
    @State private var showRun    = false
    @State private var startError: String?

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 24) {
                    heroSection
                    whatYoullLearnSection
                    whyItMattersSection
                    beforeYouStartSection
                    howItWorksSection

                    if experiment.type == .carbFactor {
                        gramsInputSection
                    }
                    if experiment.type == .isfOneUnit {
                        unitsInputSection
                    }

                    startButton
                }
                .padding()
            }
            .background(Color(.systemGroupedBackground))
            .navigationTitle(experiment.type.title)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
            }
            .sheet(isPresented: $showRun) {
                ExperimentRunView(experimentType: experiment.type, viewModel: viewModel)
                    .interactiveDismissDisabled()
            }
            .alert("Couldn't Start", isPresented: .constant(startError != nil)) {
                Button("OK") { startError = nil }
            } message: {
                Text(startError ?? "")
            }
        }
    }

    // MARK: - Sections

    private var heroSection: some View {
        HStack(spacing: 16) {
            Image(systemName: experiment.type.systemImage)
                .font(.system(size: 40))
                .foregroundStyle(Color.accentColor)
                .frame(width: 64, height: 64)
                .background(Color.accentColor.opacity(0.1))
                .clipShape(RoundedRectangle(cornerRadius: 14))

            VStack(alignment: .leading, spacing: 4) {
                Text(experiment.type.title)
                    .font(.title2.bold())
                HStack(spacing: 4) {
                    Image(systemName: "clock")
                    Text(experiment.type.durationText)
                }
                .font(.subheadline)
                .foregroundStyle(.secondary)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding()
        .background(Color(.secondarySystemGroupedBackground))
        .clipShape(RoundedRectangle(cornerRadius: 16))
    }

    private var whatYoullLearnSection: some View {
        infoSection(title: "What You'll Learn", icon: "lightbulb.fill", color: .yellow) {
            Text(experiment.type.description)
                .font(.subheadline)
        }
    }

    private var whyItMattersSection: some View {
        infoSection(title: "Why It Matters", icon: "heart.fill", color: .red) {
            Text(whyItMattersText)
                .font(.subheadline)
        }
    }

    private var beforeYouStartSection: some View {
        infoSection(title: "Before You Start", icon: "checklist", color: .green) {
            VStack(alignment: .leading, spacing: 8) {
                ForEach(experiment.type.prerequisites, id: \.self) { item in
                    Label(item, systemImage: "checkmark.circle.fill")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }
            }
        }
    }

    private var howItWorksSection: some View {
        infoSection(title: "How It Works", icon: "list.number", color: .blue) {
            VStack(alignment: .leading, spacing: 10) {
                ForEach(Array(howItWorksSteps.enumerated()), id: \.offset) { idx, step in
                    HStack(alignment: .top, spacing: 10) {
                        Text("\(idx + 1)")
                            .font(.subheadline.bold())
                            .foregroundStyle(.white)
                            .frame(width: 22, height: 22)
                            .background(Color.blue)
                            .clipShape(Circle())
                        Text(step)
                            .font(.subheadline)
                    }
                }
            }
        }
    }

    private var gramsInputSection: some View {
        infoSection(title: "Carbs to Consume", icon: "scalemass", color: .orange) {
            HStack {
                Text("Grams of fast-acting carbs:")
                    .font(.subheadline)
                Spacer()
                TextField("15", text: $gramsInput)
                    .keyboardType(.decimalPad)
                    .multilineTextAlignment(.trailing)
                    .frame(width: 60)
                    .padding(6)
                    .background(Color(.tertiarySystemFill))
                    .clipShape(RoundedRectangle(cornerRadius: 8))
                Text("g")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }
        }
    }

    private var unitsInputSection: some View {
        infoSection(title: "Insulin to Inject", icon: "syringe", color: .purple) {
            HStack {
                Text("Units of rapid insulin:")
                    .font(.subheadline)
                Spacer()
                TextField("1.0", text: $unitsInput)
                    .keyboardType(.decimalPad)
                    .multilineTextAlignment(.trailing)
                    .frame(width: 60)
                    .padding(6)
                    .background(Color(.tertiarySystemFill))
                    .clipShape(RoundedRectangle(cornerRadius: 8))
                Text("u")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }
            Text("⚠️ Only inject insulin during stable hyperglycaemia (11–14 mmol/L). Stop and treat immediately if you feel hypoglycaemic.")
                .font(.caption)
                .foregroundStyle(.orange)
                .padding(.top, 4)
        }
    }

    private var startButton: some View {
        Button {
            Task { await start() }
        } label: {
            HStack {
                if isStarting {
                    ProgressView().tint(.white)
                } else {
                    Text("Start Experiment")
                    Image(systemName: "arrow.right")
                }
            }
            .frame(maxWidth: .infinity)
            .padding()
            .background(Color.accentColor)
            .foregroundStyle(.white)
            .font(.headline)
            .clipShape(RoundedRectangle(cornerRadius: 14))
        }
        .disabled(isStarting)
        .padding(.top, 8)
    }

    // MARK: - Start logic

    private func start() async {
        isStarting = true
        defer { isStarting = false }
        do {
            let grams = experiment.type == .carbFactor ? Double(gramsInput) : nil
            let units = experiment.type == .isfOneUnit  ? Double(unitsInput) : nil
            try await viewModel.startExperiment(type: experiment.type,
                                                gramsConsumed: grams,
                                                unitsInjected: units)
            dismiss()
            showRun = true
        } catch {
            startError = error.localizedDescription
        }
    }

    // MARK: - Helpers

    @ViewBuilder
    private func infoSection<Content: View>(title: String, icon: String, color: Color,
                                            @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            Label(title, systemImage: icon)
                .font(.subheadline.bold())
                .foregroundStyle(color)
            content()
        }
        .padding()
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color(.secondarySystemGroupedBackground))
        .clipShape(RoundedRectangle(cornerRadius: 14))
    }

    private var whyItMattersText: String {
        switch experiment.type {
        case .basalCheck:
            return "Without a stable basal rate, any subsequent ISF or Carb Ratio tests will be inaccurate. This check is the foundation."
        case .carbFactor:
            return "Your Carb Ratio directly affects every mealtime dose calculation. A value that's off by 20% leads to consistent mis-dosing."
        case .isfOneUnit:
            return "Your ISF determines how much insulin to take for corrections. It changes with age, weight, fitness, and medications."
        }
    }

    private var howItWorksSteps: [String] {
        switch experiment.type {
        case .basalCheck:
            return [
                "Record your starting glucose",
                "Do not eat or take any rapid insulin",
                "App alarms every hour for readings",
                "Record each glucose at the alarm",
                "We check if glucose stayed within ±1.7 mmol/L",
            ]
        case .carbFactor:
            return [
                "Record your starting glucose",
                "Eat exactly \(gramsInput)g of fast-acting carbs — no insulin",
                "App alarms at 30 and 45 minutes",
                "Record your glucose at each alarm",
                "We calculate your Carb Factor from the peak rise",
            ]
        case .isfOneUnit:
            return [
                "Record your starting glucose (should be 11–14 mmol/L)",
                "Inject exactly \(unitsInput) unit(s) of rapid insulin — no food",
                "App alarms every hour for 4–5 hours",
                "Record each glucose at the alarm",
                "We calculate your ISF from the total drop",
            ]
        }
    }
}
