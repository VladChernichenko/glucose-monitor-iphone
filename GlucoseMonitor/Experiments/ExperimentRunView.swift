import SwiftUI

/// Live monitoring screen shown during an active experiment.
struct ExperimentRunView: View {
    let experimentType: ExperimentType
    @ObservedObject var viewModel: ExperimentViewModel
    @EnvironmentObject var appState: AppState
    @Environment(\.dismiss) private var dismiss

    @State private var showAbandonConfirm = false
    @State private var showResult = false
    @State private var elapsedSeconds: Int = 0
    @State private var timer: Timer?
    @State private var autoRecordedAt: Set<Int> = []
    @State private var safetyAlertTitle: String?
    @State private var safetyAlertMessage: String?
    @State private var alertCooldown: [String: Date] = [:]
    @State private var invalidationReason: InvalidationReason?

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
        NavigationStack {
            ScrollView {
                VStack(spacing: 20) {
                    if experimentType == .isfOneUnit, let cgm = currentCGM, cgm < 3.9 {
                        hypoBanner
                    }

                    timerCard
                    readingsCard
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
                startTimer()
                checkAutoRecord()
                checkSafety()
                checkForInvalidation(notes: appState.notes)
            }
            .onChange(of: appState.notes) { notes in
                checkForInvalidation(notes: notes)
            }
            .alert(invalidationReason?.title ?? "", isPresented: Binding(
                get: { invalidationReason != nil },
                set: { _ in }   // not dismissible — must tap the button
            )) {
                Button("Abandon Experiment", role: .destructive) {
                    let reason = invalidationReason
                    invalidationReason = nil
                    _ = reason
                    Task {
                        await viewModel.abandonExperiment()
                        dismiss()
                    }
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
            if let next = nextCheckpointText {
                VStack(alignment: .trailing, spacing: 4) {
                    Text("Next reading")
                        .font(.caption).foregroundStyle(.secondary)
                    Text(next)
                        .font(.caption2.weight(.medium))
                        .foregroundStyle(Color.accentColor)
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
                            HStack(spacing: 4) {
                                Text(r.label ?? "T+\(r.minutesElapsed) min")
                                    .font(.subheadline)
                                Image(systemName: "waveform.path.ecg")
                                    .font(.caption2)
                                    .foregroundStyle(.secondary)
                            }
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
                Text("Baseline will be captured from your CGM")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }
        }
        .padding()
        .background(Color(.secondarySystemGroupedBackground))
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

            Button {
                guard let cgm = currentCGM else { return }
                Task { await submitCurrentCGM(cgm) }
            } label: {
                HStack {
                    if viewModel.isRecordingReading {
                        ProgressView().tint(.white)
                    } else {
                        Image(systemName: "plus.circle.fill")
                        if let cgm = currentCGM {
                            Text("Add Reading Now  (\(String(format: "%.1f", cgm)) mmol/L)")
                        } else {
                            Text("Add Reading Now")
                        }
                    }
                }
                .frame(maxWidth: .infinity)
                .padding()
                .background(currentCGM != nil ? Color.accentColor : Color.gray)
                .foregroundStyle(.white)
                .clipShape(RoundedRectangle(cornerRadius: 12))
            }
            .disabled(currentCGM == nil || viewModel.isRecordingReading)
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
                Text("Waiting for at least 2 auto-captured readings before finishing")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
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

    private func submitCurrentCGM(_ cgm: Double) async {
        let elapsed = viewModel.elapsedMinutes()
        let label = (viewModel.activeExperiment?.readings ?? []).isEmpty ? "Baseline" : "T+\(elapsed) min"
        await viewModel.recordReading(glucoseMmol: cgm, minutesElapsed: elapsed, label: label)
    }

    // MARK: - Helpers

    private var nextCheckpointText: String? {
        let elapsed = viewModel.elapsedMinutes()
        guard let next = experimentType.alarmSchedule.first(where: { $0.minutes > elapsed }) else { return nil }
        let remaining = next.minutes - elapsed
        if remaining < 60 { return "in \(remaining) min" }
        let h = remaining / 60
        let m = remaining % 60
        return m == 0 ? "in \(h)h" : "in \(h)h \(m)m"
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
            if elapsedSeconds % 60 == 0 {
                checkAutoRecord()
            }
            if elapsedSeconds % 300 == 0 {
                checkSafety()
            }
        }
    }

    // MARK: - Safety monitoring

    private func checkSafety() {
        guard let cgm = currentCGM else { return }
        let arrow = appState.currentReading?.trendArrow
        let velocity = trendVelocity(arrow)

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
            if velocity >= 0.067 {
                triggerSafetyAlert(
                    id: "basal-rise",
                    title: "Glucose Rising During Basal Check",
                    message: String(format: "Your glucose is rising (%.1f mmol/L, %@). This may mean your basal rate is too low.", cgm, arrow ?? "↑")
                )
            } else if velocity <= -0.067 {
                triggerSafetyAlert(
                    id: "basal-fall",
                    title: "Glucose Falling During Basal Check",
                    message: String(format: "Your glucose is falling (%.1f mmol/L, %@). This may mean your basal rate is too high.", cgm, arrow ?? "↓")
                )
            }
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

    private func trendVelocity(_ arrow: String?) -> Double {
        switch arrow {
        case "↑↑": return  0.100
        case "↑":   return  0.067
        case "↗":   return  0.033
        case "→":   return  0.000
        case "↘":   return -0.033
        case "↓":   return -0.067
        case "↓↓": return -0.100
        default:    return  0.000
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
