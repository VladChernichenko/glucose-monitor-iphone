import SwiftUI

/// Compact verification summary section shown inside ExperimentsListView.
struct VerificationDashboardView: View {
    @StateObject private var vm = VerificationViewModel()
    @State private var showDetail = false

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Label("Real-Life Verification", systemImage: "chart.line.uptrend.xyaxis")
                .font(.headline)

            if vm.isLoading {
                ProgressView().frame(maxWidth: .infinity)
            } else if let summary = vm.summary {
                summaryContent(summary)
            } else {
                Text("No data yet - verification runs automatically as you log meals.")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }
        }
        .task { await vm.load() }
        .sheet(isPresented: $showDetail) {
            VerificationDetailView(vm: vm)
        }
        .alert("Error", isPresented: .constant(vm.error != nil)) {
            Button("OK") { vm.error = nil }
        } message: {
            Text(vm.error ?? "")
        }
    }

    @ViewBuilder
    private func summaryContent(_ s: VerificationSummary) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            // Stats row
            HStack(spacing: 16) {
                statCell(label: "Meals tracked", value: "\(s.nEvents) / 7")
                if let cs = s.consistencyScore {
                    statCell(label: "Accuracy",
                             value: String(format: "%.0f%%", cs * 100))
                }
                if let err = s.meanError {
                    statCell(label: "Avg error",
                             value: String(format: "%+.1f mmol/L", err))
                }
                confidenceBadge(s.confidence ?? "")
            }

            // Suggestion card
            if s.suggestionReady {
                suggestionCard(s)
            } else {
                Text("Analysing your last \(s.nEvents) eligible meals...")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .padding()
        .background(Color(.secondarySystemGroupedBackground))
        .clipShape(RoundedRectangle(cornerRadius: 14))
    }

    @ViewBuilder
    private func suggestionCard(_ s: VerificationSummary) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Label("Suggestion ready", systemImage: "lightbulb.fill")
                .font(.subheadline.bold())
                .foregroundStyle(.orange)

            if let cr = s.suggestedCarbRatio {
                Text("Your Carb Factor may need adjustment.")
                    .font(.subheadline)
                Group {
                    if let cur = currentCarbRatio {
                        Text("Current: \(String(format: "%.2f", cur))  ->  Suggested: \(String(format: "%.2f", cr))")
                            .font(.subheadline.monospacedDigit())
                            .foregroundStyle(.secondary)
                    }
                }
            }
            if let isf = s.suggestedIsf {
                Text("Your ISF may need adjustment.")
                    .font(.subheadline)
                Group {
                    Text("Suggested ISF: \(String(format: "%.2f", isf)) mmol/L/u")
                        .font(.subheadline.monospacedDigit())
                        .foregroundStyle(.secondary)
                }
            }

            Button { showDetail = true } label: {
                Text("Review & Apply")
                    .font(.subheadline.bold())
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 8)
                    .background(Color.orange)
                    .foregroundStyle(.white)
                    .clipShape(RoundedRectangle(cornerRadius: 10))
            }
        }
        .padding(12)
        .background(Color.orange.opacity(0.08))
        .clipShape(RoundedRectangle(cornerRadius: 10))
        .overlay(RoundedRectangle(cornerRadius: 10).stroke(Color.orange.opacity(0.3), lineWidth: 1))
    }

    @ViewBuilder
    private func statCell(label: String, value: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(value)
                .font(.subheadline.bold().monospacedDigit())
            Text(label)
                .font(.caption2)
                .foregroundStyle(.secondary)
        }
    }

    @ViewBuilder
    private func confidenceBadge(_ confidence: String) -> some View {
        let (color, label): (Color, String) = {
            switch confidence {
            case "HIGH":   return (.green,  "High")
            case "MEDIUM": return (.orange, "Medium")
            default:       return (.red,    "Low")
            }
        }()
        VStack(alignment: .leading, spacing: 2) {
            HStack(spacing: 4) {
                Circle().fill(color).frame(width: 8, height: 8)
                Text(label).font(.caption2).foregroundStyle(color)
            }
            Text("confidence").font(.caption2).foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, alignment: .trailing)
    }

    private var currentCarbRatio: Double? { nil }  // Could read from AppState/COBSettings
}
