import SwiftUI

/// Live monitoring screen shown during an active experiment.
struct ExperimentRunView: View {
    let experimentType: ExperimentType
    @ObservedObject var viewModel: ExperimentViewModel
    @EnvironmentObject var appState: AppState
    @Environment(\.dismiss) private var dismiss

    @State private var showAbandonConfirm = false
    @State private var showResult = false
    @State private var timer: Timer?
    @State private var autoRecordedAt: Set<Int> = []
    @State private var safetyAlertTitle: String?
    @State private var safetyAlertMessage: String?
    @State private var alertCooldown: [String: Date] = [:]
    @State private var invalidationReason: InvalidationReason?
    /// Forces the status banner to re-render every minute as elapsed time advances.
    @State private var elapsedTick: Int = 0

    private enum InvalidationReason {
        case insulin(Double)
        case carbs(Double)

        var title: String {
            switch self {
            case .insulin: return "Experiment Invalidated"
            case .carbs:   return "Experiment Invalidated"
            }
        }

        var message: String {
            switch self {
            case .insulin(let u):
                return String(format: "You recorded %.1fu of rapid-acting insulin during the experiment. This will affect your glucose and makes the result unreliable. The experiment has been abandoned.", u)
            case .carbs(let g):
                return String(format: "You recorded %.0fg of carbs during the experiment. This will affect your glucose and makes the result unreliable. The experiment has been abandoned.", g)
            }
        }
    }

    private var currentCGM: Double? {
        appState.currentReading?.value
    }

    var body: some View {
        navigationContent
            .alert(invalidationReason?.title ?? "", isPresented: Binding(
                get: { invalidationReason != nil },
                set: { _ in }
            )) {
                Button("Abandon Experiment", role: .destructive) {
                    invalidationReason = nil
                    Task { await viewModel.abandonExperiment(); dismiss() }
                }
            } message: {
                Text(invalidationReason?.message ?? "")
            }
            .alert(safetyAlertTitle ?? "Safety Alert", isPresented: Binding(
                get: { safetyAlertTitle != nil },
                set: { if !$0 { safetyAlertTitle = nil; safetyAlertMessage = nil } }
            )) {
                Button("OK") { safetyAlertTitle = nil; safetyAlertMessage = nil }
            } message: {
                Text(safetyAlertMessage ?? "")
            }
    }

    @ViewBuilder
    private var navigationContent: some View {
        ScrollView {
            VStack(spacing: 20) {
                if experimentType == .isfOneUnit, let cgm = currentCGM, cgm < 3.9 {
                    hypoBanner
                }
                statusBanner
                autoCaptureCard
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
        .navigationBarBackButtonHidden(true)
        .confirmationDialog("Abandon Experiment?", isPresented: $showAbandonConfirm, titleVisibility: .visible) {
            Button("Abandon", role: .destructive) {
                Task { await viewModel.abandonExperiment(); dismiss() }
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
            startTimer()
            checkAutoRecord()
            checkSafety()
            checkForInvalidation(notes: appState.notes)
        }
        .onChange(of: appState.notes.count) { _ in checkForInvalidation(notes: appState.notes) }
        .onDisappear { timer?.invalidate() }
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

    private var autoCaptureCard: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                Label("Auto-capture", systemImage: "waveform.path.ecg")
                    .font(.subheadline.bold())
                Spacer()
                if currentCGM != nil {
                    Label("Active", systemImage: "checkmark.circle.fill")
                        .font(.caption)
                        .foregroundStyle(.green)
                } else {
                    Label("No CGM signal", systemImage: "exclamationmark.circle")
                        .font(.caption)
                        .foregroundStyle(.orange)
                }
            }

            if let cgm = currentCGM {
                Text("Readings are captured automatically at each checkpoint from your CGM (currently **\(String(format: "%.1f mmol/L", cgm))**).")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            } else {
                Text("Waiting for a CGM reading. Make sure your sensor is in range.")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }
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
        let elapsed = viewModel.elapsedMinutes()
        let minMinutes = experimentType.minimumMinutesToFinish
        let hasEnoughReadings = readingCount >= 2
        let hasEnoughElapsed = elapsed >= minMinutes
        let canFinish = hasEnoughReadings && hasEnoughElapsed

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

            if !hasEnoughReadings {
                Text("Waiting for at least 2 auto-captured readings before finishing")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } else if !hasEnoughElapsed {
                Text("\(minMinutes - elapsed) more minute(s) needed for a meaningful result")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Button("Abandon") { showAbandonConfirm = true }
                .font(.subheadline)
                .foregroundStyle(.red)
                .padding(.top, 4)
        }
    }

    /// Always-visible elapsed-time + next-milestone banner. Replaces the timer card I
    /// removed earlier — without some signal of progress, a silent multi-hour experiment
    /// feels broken ("never ends"). The `elapsedTick` state binding forces a re-render
    /// every minute so the numbers actually move.
    private var statusBanner: some View {
        let elapsed = viewModel.elapsedMinutes()
        let minMinutes = experimentType.minimumMinutesToFinish
        let readyToFinish = elapsed >= minMinutes
        _ = elapsedTick // keep the binding live so SwiftUI re-evaluates on timer tick

        return HStack(alignment: .top, spacing: 12) {
            Image(systemName: readyToFinish ? "checkmark.seal.fill" : "hourglass")
                .font(.title3)
                .foregroundStyle(readyToFinish ? .green : .accentColor)
                .frame(width: 22)

            VStack(alignment: .leading, spacing: 4) {
                Text(readyToFinish ? "Ready to finish" : "In progress")
                    .font(.subheadline.weight(.semibold))
                Text(elapsedDescription(elapsed: elapsed, minMinutes: minMinutes, readyToFinish: readyToFinish))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 0)
        }
        .padding()
        .frame(maxWidth: .infinity, alignment: .leading)
        .background((readyToFinish ? Color.green : Color.accentColor).opacity(0.10))
        .overlay(
            RoundedRectangle(cornerRadius: 14)
                .strokeBorder((readyToFinish ? Color.green : Color.accentColor).opacity(0.3), lineWidth: 1)
        )
        .clipShape(RoundedRectangle(cornerRadius: 14))
    }

    private func elapsedDescription(elapsed: Int, minMinutes: Int, readyToFinish: Bool) -> String {
        let elapsedText = formatMinutes(elapsed)
        if readyToFinish {
            return "Running for \(elapsedText) — tap Finish below to see your result."
        }
        if let nextMessage = viewModel.nextAlarmLabel {
            return "Running for \(elapsedText). \(nextMessage)"
        }
        let remaining = minMinutes - elapsed
        return "Running for \(elapsedText). \(formatMinutes(remaining)) until you can finish."
    }

    private func formatMinutes(_ minutes: Int) -> String {
        let m = max(0, minutes)
        if m < 60 { return "\(m) min" }
        let hours = m / 60
        let mins = m % 60
        return mins == 0 ? "\(hours) h" : "\(hours) h \(mins) min"
    }

    // MARK: - Auto-capture

    private func checkAutoRecord() {
        guard let cgm = currentCGM else { return }
        let elapsed = viewModel.elapsedMinutes()
        let existingReadings = viewModel.activeExperiment?.readings ?? []

        let checkpoints = [0] + experimentType.alarmSchedule.map(\.minutes)
        for minute in checkpoints {
            guard elapsed >= minute, !autoRecordedAt.contains(minute) else { continue }
            // Skip if the server already has a reading within ±1 min of this checkpoint
            let alreadySaved = existingReadings.contains { abs($0.minutesElapsed - minute) <= 1 }
            autoRecordedAt.insert(minute)
            guard !alreadySaved else { continue }
            let label = minute == 0 ? "Baseline" : "T+\(minute) min"
            Task {
                await viewModel.recordReading(glucoseMmol: cgm, minutesElapsed: minute, label: label)
            }
        }
    }


    private func startTimer() {
        timer = Timer.scheduledTimer(withTimeInterval: 60, repeats: true) { _ in
            checkAutoRecord()
            checkSafety()
            // Bump the tick to force the status banner to re-render with the new
            // elapsed-minutes value. Without this nudge SwiftUI doesn't know the
            // computed elapsedMinutes() has changed (it's not @Published).
            elapsedTick &+= 1
        }
    }

    // MARK: - Safety monitoring

    private func checkSafety() {
        guard let cgm = currentCGM else { return }
        let arrow = appState.currentReading?.trendArrow
        let velocity = BackendAPI.trendArrowToVelocity(arrow)

        if cgm < 3.9 {
            triggerSafetyAlert(
                id: "hypo",
                title: "Low Glucose — Stop Experiment",
                message: String(format: "Your glucose is %.1f mmol/L. Treat hypoglycaemia immediately and stop the experiment.", cgm)
            )
            return
        }

        switch experimentType {
        case .basalCheck:
            // Baseline experiment — runs silently. Glucose drift during the check is
            // exactly what the experiment measures; surfacing it as an alert is noise.
            // The hypo guard above still fires because <3.9 mmol/L is a safety floor,
            // not a drift signal.
            break
        case .carbFactor:
            if velocity <= -0.067 {
                triggerSafetyAlert(
                    id: "carb-fall",
                    title: "Unexpected Glucose Drop",
                    message: String(format: "Your glucose is falling (%.1f mmol/L) during a Carb Factor test. Check your insulin on board.", cgm)
                )
            }
        case .isfOneUnit:
            if velocity <= -0.100 {
                triggerSafetyAlert(
                    id: "isf-rapid-fall",
                    title: "Glucose Dropping Very Fast",
                    message: String(format: "Your glucose is dropping rapidly (%.1f mmol/L, %@). Be ready to treat if you approach 4 mmol/L.", cgm, arrow ?? "↓↓")
                )
            }
        }
    }

    private func triggerSafetyAlert(id: String, title: String, message: String) {
        let now = Date()
        if let last = alertCooldown[id], now.timeIntervalSince(last) < 1800 { return }
        alertCooldown[id] = now
        safetyAlertTitle = title
        safetyAlertMessage = message
        Task {
            await ExperimentAlarmManager.shared.fireSafetyNotification(id: id, title: title, body: message)
        }
    }

    // MARK: - Invalidation detection

    private func checkForInvalidation(notes: [BackendAPI.GlucoseNote]) {
        guard invalidationReason == nil else { return }
        guard let startedAt = viewModel.activeExperiment?.startedAt,
              let startDate = ISO8601DateFormatter().date(from: startedAt) else { return }

        for note in notes {
            guard let ts = note.timestamp, ts > startDate else { continue }
            if note.insulin > 0 && !note.isLongActing {
                invalidationReason = .insulin(note.insulin)
                return
            }
            if note.carbs > 0 {
                invalidationReason = .carbs(note.carbs)
                return
            }
        }
    }

}
