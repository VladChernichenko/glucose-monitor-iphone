import SwiftUI

/// Live monitoring screen shown during an active experiment.
struct ExperimentRunView: View {
    let experimentType: ExperimentType
    @ObservedObject var viewModel: ExperimentViewModel
    @EnvironmentObject var appState: AppState
    @Environment(\.dismiss) private var dismiss

    @State private var glucoseInput: String = ""
    @State private var showAbandonConfirm = false
    @State private var showResult = false
    @State private var elapsedSeconds: Int = 0
    @State private var timer: Timer?

    private var currentCGM: Double? {
        appState.currentReading?.value
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 20) {
                    // Hypo safety banner (ISF test only)
                    if experimentType == .isfOneUnit, let cgm = currentCGM, cgm < 3.9 {
                        hypoBanner
                    }

                    timerCard
                    readingsCard
                    recordCard

                    if experimentType != .basalCheck {
                        safetyNote
                    }

                    completeButton
                }
                .padding()
            }
            .background(Color(.systemGroupedBackground))
            .navigationTitle(experimentType.title)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Abandon") { showAbandonConfirm = true }
                        .foregroundStyle(.red)
                }
            }
            .confirmationDialog("Abandon Experiment?", isPresented: $showAbandonConfirm, titleVisibility: .visible) {
                Button("Abandon", role: .destructive) {
                    Task {
                        await viewModel.abandonExperiment()
                        dismiss()
                    }
                }
                Button("Keep Going", role: .cancel) {}
            } message: {
                Text("Your data will be discarded. You can start a new experiment any time.")
            }
            .sheet(isPresented: $showResult) {
                if let result = viewModel.lastResult {
                    ExperimentResultView(result: result, onDone: { dismiss() })
                }
            }
            .onAppear {
                prefillGlucose()
                startTimer()
            }
            .onDisappear { timer?.invalidate() }
        }
    }

    // MARK: - Sub-views

    private var hypoBanner: some View {
        HStack(spacing: 10) {
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundStyle(.white)
            VStack(alignment: .leading, spacing: 2) {
                Text("Low Glucose Detected").font(.subheadline.bold()).foregroundStyle(.white)
                Text("Stop the experiment and treat hypoglycaemia immediately.")
                    .font(.caption).foregroundStyle(.white.opacity(0.9))
            }
        }
        .padding()
        .frame(maxWidth: .infinity)
        .background(Color.red)
        .clipShape(RoundedRectangle(cornerRadius: 14))
    }

    private var timerCard: some View {
        HStack {
            VStack(alignment: .leading, spacing: 4) {
                Text("Elapsed Time")
                    .font(.caption).foregroundStyle(.secondary)
                Text(elapsedText)
                    .font(.title2.monospacedDigit().bold())
            }
            Spacer()
            if let next = viewModel.nextAlarmLabel {
                VStack(alignment: .trailing, spacing: 4) {
                    Text("Next alarm")
                        .font(.caption).foregroundStyle(.secondary)
                    Text(next.prefix(30) + "…")
                        .font(.caption2)
                        .foregroundStyle(Color.accentColor)
                        .multilineTextAlignment(.trailing)
                }
            }
        }
        .padding()
        .background(Color(.secondarySystemGroupedBackground))
        .clipShape(RoundedRectangle(cornerRadius: 14))
    }

    private var readingsCard: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Readings")
                .font(.subheadline.bold())

            if let readings = viewModel.activeExperiment?.readings, !readings.isEmpty {
                ForEach(readings) { r in
                    HStack {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(r.label ?? "T+\(r.minutesElapsed) min")
                                .font(.subheadline)
                            Text(shortTime(r.recordedAt))
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                        Spacer()
                        Text(String(format: "%.1f mmol/L", r.glucoseMmol))
                            .font(.subheadline.monospacedDigit())
                            .foregroundStyle(.primary)
                    }
                    .padding(.vertical, 4)
                    if r.id != readings.last?.id { Divider() }
                }
            } else {
                Text("No readings recorded yet")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }
        }
        .padding()
        .background(Color(.secondarySystemGroupedBackground))
        .clipShape(RoundedRectangle(cornerRadius: 14))
    }

    private var recordCard: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Record Reading")
                .font(.subheadline.bold())

            if let cgm = currentCGM {
                Button {
                    glucoseInput = String(format: "%.1f", cgm)
                } label: {
                    HStack {
                        Image(systemName: "waveform.path.ecg")
                        Text(String(format: "Use CGM: %.1f mmol/L", cgm))
                        Spacer()
                        Image(systemName: "arrow.down.circle")
                    }
                    .font(.subheadline)
                    .padding(10)
                    .background(Color.accentColor.opacity(0.1))
                    .clipShape(RoundedRectangle(cornerRadius: 10))
                }
                .buttonStyle(.plain)
            }

            HStack {
                Text("Or enter manually:")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                TextField("mmol/L", text: $glucoseInput)
                    .keyboardType(.decimalPad)
                    .multilineTextAlignment(.trailing)
                    .padding(8)
                    .background(Color(.tertiarySystemFill))
                    .clipShape(RoundedRectangle(cornerRadius: 8))
                    .frame(maxWidth: 100)
                Text("mmol/L").font(.subheadline).foregroundStyle(.secondary)
            }

            Button {
                Task { await submitReading() }
            } label: {
                HStack {
                    if viewModel.isRecordingReading {
                        ProgressView().tint(.white)
                    } else {
                        Text("Record")
                        Image(systemName: "checkmark.circle.fill")
                    }
                }
                .frame(maxWidth: .infinity)
                .padding()
                .background(validGlucose != nil ? Color.accentColor : Color.gray)
                .foregroundStyle(.white)
                .clipShape(RoundedRectangle(cornerRadius: 12))
            }
            .disabled(validGlucose == nil || viewModel.isRecordingReading)
        }
        .padding()
        .background(Color(.secondarySystemGroupedBackground))
        .clipShape(RoundedRectangle(cornerRadius: 14))
    }

    private var safetyNote: some View {
        Label(
            experimentType == .isfOneUnit
            ? "Do not correct glucose during the test unless you drop below 3.9 mmol/L — then stop and treat."
            : "Do not take any insulin or eat additional food during this test.",
            systemImage: "shield.lefthalf.filled"
        )
        .font(.caption)
        .foregroundStyle(.secondary)
        .padding()
        .background(Color(.secondarySystemGroupedBackground))
        .clipShape(RoundedRectangle(cornerRadius: 12))
    }

    private var completeButton: some View {
        let readingCount = viewModel.activeExperiment?.readings.count ?? 0
        let canFinish = readingCount >= 2

        return VStack(spacing: 8) {
            Button {
                Task {
                    await viewModel.completeExperiment()
                    if viewModel.lastResult != nil { showResult = true }
                }
            } label: {
                HStack {
                    if viewModel.isCompleting {
                        ProgressView().tint(.white)
                    } else {
                        Text("Finish & See Result")
                        Image(systemName: "flag.checkered")
                    }
                }
                .frame(maxWidth: .infinity)
                .padding()
                .background(canFinish ? Color.green : Color.gray)
                .foregroundStyle(.white)
                .font(.headline)
                .clipShape(RoundedRectangle(cornerRadius: 14))
            }
            .disabled(!canFinish || viewModel.isCompleting)

            if !canFinish {
                Text("Record at least 2 glucose readings before finishing")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }

    // MARK: - Helpers

    private var validGlucose: Double? {
        Double(glucoseInput.replacingOccurrences(of: ",", with: "."))
    }

    private var elapsedText: String {
        let h = elapsedSeconds / 3600
        let m = (elapsedSeconds % 3600) / 60
        let s = elapsedSeconds % 60
        return h > 0
            ? String(format: "%d:%02d:%02d", h, m, s)
            : String(format: "%02d:%02d", m, s)
    }

    private func startTimer() {
        timer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { _ in
            elapsedSeconds += 1
        }
    }

    private func prefillGlucose() {
        if let cgm = currentCGM {
            glucoseInput = String(format: "%.1f", cgm)
        }
    }

    private func submitReading() async {
        guard let glucose = validGlucose else { return }
        let label = readingLabel(for: viewModel.elapsedMinutes())
        await viewModel.recordReading(
            glucoseMmol: glucose,
            minutesElapsed: viewModel.elapsedMinutes(),
            label: label
        )
        glucoseInput = ""
        prefillGlucose()
    }

    private func readingLabel(for minutes: Int) -> String {
        if (viewModel.activeExperiment?.readings ?? []).isEmpty { return "Baseline" }
        return "T+\(minutes) min"
    }

    private func shortTime(_ isoString: String) -> String {
        let f = ISO8601DateFormatter()
        if let date = f.date(from: isoString) {
            let out = DateFormatter()
            out.timeStyle = .short
            out.dateStyle = .none
            return out.string(from: date)
        }
        return isoString
    }
}
