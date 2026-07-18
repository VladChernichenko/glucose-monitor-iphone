import SwiftUI

/// Shown when a user tries to start an experiment but IOB/COB are too high.
struct BackgroundCheckView: View {
    let status: BackgroundStatus
    let experimentType: ExperimentType
    let onDismiss: () -> Void

    @State private var notifyWhenReady: Bool

    init(status: BackgroundStatus, experimentType: ExperimentType, onDismiss: @escaping () -> Void) {
        self.status = status
        self.experimentType = experimentType
        self.onDismiss = onDismiss
        _notifyWhenReady = State(initialValue: ExperimentNotifyPreference.isEnabled(for: experimentType))
    }

    var body: some View {
        VStack(spacing: 0) {
            // Header
            VStack(spacing: 12) {
                Image(systemName: "clock.badge.exclamationmark")
                    .font(.system(size: 52))
                    .foregroundStyle(.orange)
                Text("Not Ready Yet")
                    .font(.title2.bold())
                Text("To get accurate results, your body needs a neutral metabolic state - no active insulin or carbs.")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal)
            }
            .padding(.top, 32)
            .padding(.bottom, 24)

            // COB / IOB bars
            VStack(spacing: 14) {
                substanceBar(
                    icon: "fork.knife",
                    label: "Active Carbs",
                    value: status.cobGrams,
                    max: 30,
                    threshold: 5,
                    unit: "g",
                    color: .orange
                )
                substanceBar(
                    icon: "syringe",
                    label: "Active Insulin",
                    value: status.iobUnits,
                    max: 3,
                    threshold: 0.3,
                    unit: "u",
                    color: .blue
                )
            }
            .padding(.horizontal)
            .padding(.bottom, 20)

            // Countdown
            HStack(spacing: 6) {
                Image(systemName: "hourglass")
                    .foregroundStyle(.secondary)
                Text("Estimated clean in:")
                    .foregroundStyle(.secondary)
                Text(cleanInText)
                    .fontWeight(.semibold)
            }
            .font(.subheadline)
            .padding(.bottom, 24)

            // Notify toggle
            Toggle(isOn: $notifyWhenReady) {
                HStack(spacing: 8) {
                    Image(systemName: "bell.fill")
                        .foregroundStyle(Color.accentColor)
                    Text("Notify me when ready")
                        .font(.subheadline)
                }
            }
            .toggleStyle(SwitchToggleStyle(tint: Color.accentColor))
            .padding(.horizontal)
            .onChange(of: notifyWhenReady) { enabled in
                ExperimentNotifyPreference.setEnabled(enabled, for: experimentType)
                if enabled {
                    Task {
                        await ExperimentAlarmManager.shared
                            .scheduleBackgroundCleanNotification(
                                in: status.cleanInMinutes,
                                experimentType: experimentType
                            )
                    }
                }
            }
            .padding(.bottom, 32)

            Spacer()

            Button("Got it") { onDismiss() }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
                .padding(.horizontal)
                .padding(.bottom, 32)
        }
        .background(Color(.systemGroupedBackground))
    }

    private var cleanInText: String {
        let m = status.cleanInMinutes
        if m < 60 { return "\(m) min" }
        let h = m / 60
        let rem = m % 60
        return rem == 0 ? "\(h)h" : "\(h)h \(rem)m"
    }

    @ViewBuilder
    private func substanceBar(icon: String, label: String, value: Double,
                               max: Double, threshold: Double, unit: String, color: Color) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Label(label, systemImage: icon)
                    .font(.subheadline.weight(.medium))
                Spacer()
                Text(String(format: "%.1f \(unit)", value))
                    .font(.subheadline.monospacedDigit())
                    .foregroundStyle(value > threshold ? color : .green)
            }
            GeometryReader { geo in
                ZStack(alignment: .leading) {
                    RoundedRectangle(cornerRadius: 4)
                        .fill(Color(.systemFill))
                        .frame(height: 8)
                    RoundedRectangle(cornerRadius: 4)
                        .fill(value > threshold ? color : .green)
                        .frame(width: min(CGFloat(value / max), 1.0) * geo.size.width, height: 8)
                        .animation(.easeOut(duration: 0.4), value: value)
                }
            }
            .frame(height: 8)
        }
        .padding(14)
        .background(Color(.secondarySystemGroupedBackground))
        .clipShape(RoundedRectangle(cornerRadius: 12))
    }
}
