import SwiftUI

// MARK: - Root

struct ContentView: View {
    @EnvironmentObject var appState: AppState

    var body: some View {
        TabView {
            DashboardView()
                .tabItem { Label("Dashboard", systemImage: "waveform.path.ecg") }
            NotesView()
                .tabItem { Label("Notes", systemImage: "note.text") }
            SettingsView()
                .tabItem { Label("Settings", systemImage: "gearshape") }
        }
        .onAppear {
            appState.checkAuthentication()
        }
    }
}

// MARK: - Dashboard

struct DashboardView: View {
    @EnvironmentObject var appState: AppState

    var body: some View {
        NavigationStack {
            Group {
                if !appState.isAuthenticated {
                    notSignedInPlaceholder
                } else {
                    ScrollView {
                        VStack(spacing: 20) {
                            glucoseCard
                            if let calc = appState.calculations {
                                calculationsCard(calc)
                            }
                            if let msg = appState.errorMessage {
                                Text(msg)
                                    .font(.footnote)
                                    .foregroundColor(.red)
                                    .multilineTextAlignment(.center)
                                    .padding(.horizontal)
                            }
                        }
                        .padding()
                    }
                }
            }
            .navigationTitle("Glucose Monitor")
            .toolbar {
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button {
                        Task { await appState.refreshAll() }
                    } label: {
                        if appState.isLoading {
                            ProgressView()
                        } else {
                            Image(systemName: "arrow.clockwise")
                        }
                    }
                    .disabled(appState.isLoading || !appState.isAuthenticated)
                }
            }
            .task {
                if appState.isAuthenticated && appState.currentReading == nil {
                    await appState.refreshAll()
                }
            }
        }
    }

    // MARK: Cards

    private var glucoseCard: some View {
        VStack(spacing: 12) {
            if appState.isLoading && appState.currentReading == nil {
                ProgressView("Loading…")
                    .frame(maxWidth: .infinity)
                    .padding()
            } else if let r = appState.currentReading, let v = r.value {
                HStack(alignment: .firstTextBaseline, spacing: 6) {
                    Text(formatGlucose(v, unit: r.unit))
                        .font(.system(size: 56, weight: .bold, design: .rounded))
                        .monospacedDigit()
                    Text(unitLabel(r.unit))
                        .font(.title3)
                        .foregroundColor(.secondary)
                    if let arrow = r.trendArrow, !arrow.isEmpty {
                        Text(arrow)
                            .font(.system(size: 36, weight: .medium))
                    }
                }

                if let status = r.status {
                    statusBadge(status)
                }

                if let ts = r.timestamp {
                    Text("Updated ")
                        .font(.footnote)
                        .foregroundColor(.secondary)
                    + Text(ts, style: .relative)
                        .font(.footnote)
                        .foregroundColor(.secondary)
                    + Text(" ago")
                        .font(.footnote)
                        .foregroundColor(.secondary)
                }
            } else {
                VStack(spacing: 8) {
                    Image(systemName: "drop.circle")
                        .font(.system(size: 44))
                        .foregroundColor(.secondary)
                    Text("No reading yet")
                        .foregroundColor(.secondary)
                    Text("Tap ↻ to refresh")
                        .font(.footnote)
                        .foregroundColor(.secondary.opacity(0.75))
                }
                .padding()
            }
        }
        .frame(maxWidth: .infinity)
        .padding()
        .background(Color(.systemBackground))
        .clipShape(RoundedRectangle(cornerRadius: 16))
        .shadow(color: .black.opacity(0.07), radius: 8, y: 2)
    }

    private func calculationsCard(_ calc: BackendAPI.GlucoseCalculationsResponse) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Active Calculations")
                .font(.headline)

            HStack(spacing: 0) {
                calculationCell(
                    icon: "fork.knife",
                    value: String(format: "%.0f g", calc.activeCarbsOnBoard),
                    label: "COB"
                )
                Divider().frame(height: 44)
                calculationCell(
                    icon: "cross.vial",
                    value: String(format: "%.1f u", calc.activeInsulinOnBoard),
                    label: "IOB"
                )
                Divider().frame(height: 44)
                calculationCell(
                    icon: trendIcon(calc.predictionTrend),
                    value: formatGlucose(calc.twoHourPrediction, unit: appState.currentReading?.unit),
                    label: "2 h Pred."
                )
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding()
        .background(Color(.systemBackground))
        .clipShape(RoundedRectangle(cornerRadius: 16))
        .shadow(color: .black.opacity(0.07), radius: 8, y: 2)
    }

    private func calculationCell(icon: String, value: String, label: String) -> some View {
        VStack(spacing: 4) {
            Image(systemName: icon)
                .font(.title3)
                .foregroundColor(.secondary)
            Text(value)
                .font(.headline.monospacedDigit())
            Text(label)
                .font(.caption)
                .foregroundColor(.secondary)
        }
        .frame(maxWidth: .infinity)
    }

    // MARK: Placeholder

    private var notSignedInPlaceholder: some View {
        VStack(spacing: 16) {
            Image(systemName: "person.badge.key")
                .font(.system(size: 56))
                .foregroundColor(.secondary)
            Text("Not signed in")
                .font(.title2.bold())
            Text("Open Settings to configure your backend and sign in.")
                .font(.subheadline)
                .foregroundColor(.secondary)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 32)
        }
    }

    // MARK: Helpers

    private func statusBadge(_ status: String) -> some View {
        let label: String
        let color: Color
        switch status.lowercased() {
        case "critical": label = "Critical"; color = .red
        case "low":      label = "Low";      color = .orange
        case "high":     label = "High";     color = Color(red: 0.85, green: 0.55, blue: 0)
        default:         label = "Normal";   color = .green
        }
        return Text(label)
            .font(.caption.bold())
            .padding(.horizontal, 10)
            .padding(.vertical, 4)
            .background(color.opacity(0.15))
            .foregroundColor(color)
            .clipShape(Capsule())
    }

    private func formatGlucose(_ value: Double, unit: String?) -> String {
        (unit ?? "mmol/L").lowercased().contains("mg")
            ? String(format: "%.0f", value)
            : String(format: "%.1f", value)
    }

    private func unitLabel(_ unit: String?) -> String {
        (unit ?? "mmol/L").lowercased().contains("mg") ? "mg/dL" : "mmol/L"
    }

    private func trendIcon(_ trend: String) -> String {
        switch trend.lowercased() {
        case "rising":  return "arrow.up.right"
        case "falling": return "arrow.down.right"
        default:        return "arrow.right"
        }
    }
}