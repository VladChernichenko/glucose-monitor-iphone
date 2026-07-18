import SwiftUI

struct ExperimentsListView: View {
    @EnvironmentObject private var vm: ExperimentViewModel
    @State private var selectedExperiment: AvailableExperiment?
    @State private var showBackgroundBlock: (BackgroundStatus, ExperimentType)?
    @State private var showDetail: AvailableExperiment?
    @State private var showRun = false

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 20) {
                    headerBanner

                    if vm.hasActiveExperiment {
                        activeCard
                    }

                    if vm.isLoadingAvailable {
                        ProgressView().padding()
                    } else {
                        experimentsSection
                    }

                    verificationSection

                    IsfMealWindowChart()
                        .environmentObject(vm)

                    if !vm.history.isEmpty {
                        historySection
                    }
                }
                .padding(.horizontal)
                .padding(.bottom, 32)
            }
            .background(Color(.systemGroupedBackground))
            .navigationTitle("Experiments")
            .toolbar {
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button { Task { await vm.loadAvailable() } } label: {
                        Image(systemName: "arrow.clockwise")
                    }
                }
            }
            .task { await vm.loadAvailable() }
            .sheet(item: $showDetail) { exp in
                ExperimentDetailView(experiment: exp, viewModel: vm)
            }
            .navigationDestination(isPresented: $showRun) {
                if let active = vm.activeExperiment {
                    ExperimentRunView(experimentType: active.type, viewModel: vm)
                }
            }
            .sheet(item: Binding(
                get: { showBackgroundBlock.map { BlockItem(status: $0.0, type: $0.1) } },
                set: { if $0 == nil { showBackgroundBlock = nil } }
            )) { item in
                BackgroundCheckView(
                    status: item.status,
                    experimentType: item.type,
                    onDismiss: { showBackgroundBlock = nil }
                )
                .presentationDetents([.large])
            }
            .alert("Error", isPresented: .constant(vm.error != nil), actions: {
                Button("OK") { vm.error = nil }
            }, message: { Text(vm.error ?? "") })
        }
    }

    // MARK: - Sub-views

    private var headerBanner: some View {
        VStack(alignment: .leading, spacing: 6) {
            Label("Discover Your Settings", systemImage: "flask.fill")
                .font(.headline)
            Text("Run guided experiments to find your personal Insulin Sensitivity Factor and Carb Ratio.")
                .font(.subheadline)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding()
        .background(Color(.secondarySystemGroupedBackground))
        .clipShape(RoundedRectangle(cornerRadius: 14))
    }

    private var activeCard: some View {
        Button { showRun = true } label: {
            HStack {
                VStack(alignment: .leading, spacing: 4) {
                    Label("Experiment in Progress", systemImage: "timer")
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(.white)
                    if let type = vm.activeExperiment?.type {
                        Text(type.title)
                            .font(.caption)
                            .foregroundStyle(.white.opacity(0.85))
                    }
                }
                Spacer()
                Image(systemName: "chevron.right")
                    .foregroundStyle(.white.opacity(0.7))
            }
            .padding()
            .background(Color.accentColor)
            .clipShape(RoundedRectangle(cornerRadius: 14))
        }
        .buttonStyle(.plain)
    }

    private var experimentsSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Available Experiments")
                .font(.headline)
                .padding(.top, 4)

            if vm.hasActiveExperiment {
                HStack(spacing: 10) {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .foregroundStyle(.orange)
                    Text("An experiment is already in progress. Finish or abandon it before starting a new one.")
                        .font(.subheadline)
                        .foregroundStyle(.primary)
                }
                .padding()
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(Color.orange.opacity(0.12))
                .clipShape(RoundedRectangle(cornerRadius: 12))
            }

            ForEach(vm.availableExperiments) { exp in
                ExperimentCard(experiment: exp, experimentInProgress: vm.hasActiveExperiment) {
                    handleTap(exp)
                }
            }
        }
    }

    private var verificationSection: some View {
        VerificationDashboardView()
    }

    private var historySection: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Past Results")
                .font(.headline)
                .padding(.top, 4)

            ForEach(vm.history.prefix(5)) { item in
                HStack {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(item.type.title)
                            .font(.subheadline.weight(.medium))
                        if let ts = item.completedAt {
                            Text(shortDate(ts))
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                    Spacer()
                    resultBadge(for: item)
                }
                .padding(12)
                .background(Color(.secondarySystemGroupedBackground))
                .clipShape(RoundedRectangle(cornerRadius: 12))
            }
        }
    }

    @ViewBuilder
    private func resultBadge(for item: ExperimentModel) -> some View {
        if let isf = item.computedIsf {
            Text(String(format: "ISF %.2f", isf))
                .font(.caption.monospacedDigit())
                .padding(.horizontal, 8).padding(.vertical, 4)
                .background(Color.blue.opacity(0.15))
                .foregroundStyle(.blue)
                .clipShape(Capsule())
        } else if let cr = item.computedCarbRatio {
            Text(String(format: "CR %.2f", cr))
                .font(.caption.monospacedDigit())
                .padding(.horizontal, 8).padding(.vertical, 4)
                .background(Color.orange.opacity(0.15))
                .foregroundStyle(.orange)
                .clipShape(Capsule())
        } else if let stable = item.isStable {
            Text(stable ? "Stable OK" : "Unstable ✗")
                .font(.caption)
                .padding(.horizontal, 8).padding(.vertical, 4)
                .background(stable ? Color.green.opacity(0.15) : Color.red.opacity(0.15))
                .foregroundStyle(stable ? .green : .red)
                .clipShape(Capsule())
        }
    }

    // MARK: - Actions

    private func handleTap(_ exp: AvailableExperiment) {
        guard exp.available else { return }   // locked - card shows lock reason
        if vm.hasActiveExperiment {
            showRun = true
            return
        }
        Task {
            await vm.checkBackground()
            if let bg = vm.backgroundStatus, !bg.isClean {
                showBackgroundBlock = (bg, exp.type)
            } else {
                showDetail = exp
            }
        }
    }

    private func shortDate(_ isoString: String) -> String {
        let f = ISO8601DateFormatter()
        if let date = f.date(from: isoString) {
            let out = DateFormatter()
            out.dateStyle = .medium
            out.timeStyle = .none
            return out.string(from: date)
        }
        return isoString
    }
}

// MARK: - Experiment Card

private struct ExperimentCard: View {
    let experiment: AvailableExperiment
    var experimentInProgress: Bool = false
    let onTap: () -> Void

    var body: some View {
        Button(action: onTap) {
            VStack(alignment: .leading, spacing: 10) {
                HStack(alignment: .top) {
                    Image(systemName: experiment.type.systemImage)
                        .font(.title3)
                        .foregroundStyle(experiment.available ? Color.accentColor : Color.secondary)
                        .frame(width: 32)

                    VStack(alignment: .leading, spacing: 3) {
                        Text(experiment.type.title)
                            .font(.subheadline.weight(.semibold))
                            .foregroundStyle(experiment.available ? .primary : .secondary)
                        Text(experiment.type.subtitle)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }

                    Spacer()

                    statusBadge
                }

                Text(experiment.type.description)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(3)

                HStack {
                    Label(experiment.type.durationText, systemImage: "clock")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                    Spacer()
                    if !experiment.available, let reason = experiment.lockReason {
                        Label(reason, systemImage: "lock.fill")
                            .font(.caption2)
                            .foregroundStyle(.orange)
                            .lineLimit(1)
                    } else if experiment.available && experimentInProgress {
                        Label("In progress", systemImage: "clock.fill")
                            .font(.caption2)
                            .foregroundStyle(.orange)
                    } else if experiment.available {
                        Text("Start ->")
                            .font(.caption.weight(.medium))
                            .foregroundStyle(Color.accentColor)
                    }
                }
            }
            .padding(14)
            .background(Color(.secondarySystemGroupedBackground))
            .clipShape(RoundedRectangle(cornerRadius: 14))
            .overlay(
                RoundedRectangle(cornerRadius: 14)
                    .strokeBorder(experiment.available ? Color.accentColor.opacity(0.3) : Color.clear, lineWidth: 1)
            )
        }
        .buttonStyle(.plain)
        .disabled(!experiment.available)
    }

    @ViewBuilder
    private var statusBadge: some View {
        if experiment.available {
            if hasResult {
                Image(systemName: "checkmark.circle.fill")
                    .foregroundStyle(.green)
            } else {
                Image(systemName: "circle")
                    .foregroundStyle(Color.accentColor)
            }
        } else {
            Image(systemName: "lock.fill")
                .foregroundStyle(.secondary)
        }
    }

    private var hasResult: Bool {
        experiment.lastComputedIsf != nil ||
        experiment.lastComputedCarbRatio != nil ||
        experiment.lastIsStable != nil
    }
}

// Helper for sheet binding
private struct BlockItem: Identifiable {
    let id = UUID()
    let status: BackgroundStatus
    let type: ExperimentType
}
