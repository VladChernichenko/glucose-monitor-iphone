import SwiftUI
import Charts

/// Per-meal-window observational ISF chart shown inside the ISF result view.
///
/// One bar per window (Breakfast / Lunch / Dinner). Buckets without enough data
/// (< 7 weighted samples on the backend) render as a faded placeholder bar with a
/// "Run ISF experiment" CTA. Refresh-on-appear; explicit recompute button kicks
/// the backend's on-demand path.
struct IsfMealWindowChart: View {
    @EnvironmentObject private var experimentVM: ExperimentViewModel

    @State private var profile: BackendAPI.IsfMealWindowProfile?
    @State private var isLoading = false
    @State private var bannerError: BannerError?

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            header
            // Banner sits between header and chart so it never replaces the chart on
            // action errors (e.g. "Run test" 409). Load errors hide the chart only when
            // we have no cached profile to fall back on.
            if let err = bannerError {
                ErrorBanner(error: err) { bannerError = nil }
            }
            content
        }
        .padding()
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color(.secondarySystemGroupedBackground))
        .clipShape(RoundedRectangle(cornerRadius: 14))
        .task { await load() }
    }

    // MARK: - Sections

    private var header: some View {
        HStack(alignment: .top) {
            VStack(alignment: .leading, spacing: 4) {
                Label("Your ISF Across the Day", systemImage: "chart.bar.xaxis")
                    .font(.subheadline.bold())
                    .foregroundStyle(.purple)
                if let p = profile {
                    Text("From the last \(p.historyDays) days of bolus events.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                } else {
                    Text("Observational estimate — refines daily.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            Spacer()
            Button {
                Task { await recompute() }
            } label: {
                if isLoading {
                    ProgressView().controlSize(.small)
                } else {
                    Image(systemName: "arrow.clockwise")
                        .font(.subheadline)
                        .foregroundStyle(.purple)
                }
            }
            .disabled(isLoading)
        }
    }

    @ViewBuilder
    private var content: some View {
        if let p = profile {
            chartFor(p)
        } else if isLoading {
            ProgressView().frame(maxWidth: .infinity, alignment: .center)
        } else if bannerError == nil {
            // First render before .task fires
            Color.clear.frame(height: 1)
        }
    }

    private func chartFor(_ p: BackendAPI.IsfMealWindowProfile) -> some View {
        let displayMax = (p.windows.compactMap(\.isfMmolPerU).max() ?? 4.0) * 1.15

        return VStack(alignment: .leading, spacing: 12) {
            Chart {
                ForEach(p.windows) { window in
                    if let isf = window.isfMmolPerU {
                        BarMark(
                            x: .value("Meal", window.displayName),
                            y: .value("ISF", isf)
                        )
                        .foregroundStyle(barColor(for: window.mealWindow))
                        .annotation(position: .top) {
                            Text(String(format: "%.2f", isf))
                                .font(.caption.monospacedDigit())
                                .foregroundStyle(.primary)
                        }
                    } else {
                        // Gap placeholder — a faint bar so the slot is visible
                        BarMark(
                            x: .value("Meal", window.displayName),
                            y: .value("ISF", max(displayMax * 0.25, 0.5))
                        )
                        .foregroundStyle(Color.gray.opacity(0.12))
                        .annotation(position: .top) {
                            Image(systemName: "questionmark.circle")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                }
            }
            .chartYAxisLabel("mmol/L per unit", position: .leading)
            .frame(height: 180)

            ForEach(p.windows) { window in
                bucketRow(window)
            }
        }
    }

    private func bucketRow(_ window: BackendAPI.IsfMealWindow) -> some View {
        HStack(alignment: .center, spacing: 10) {
            Circle()
                .fill(barColor(for: window.mealWindow))
                .frame(width: 8, height: 8)

            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text(window.displayName).font(.subheadline.weight(.medium))
                    Text(window.rangeLabel)
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
                if let isf = window.isfMmolPerU, let raw = window.rawSampleCount {
                    Text(String(format: "ISF %.2f • %d events", isf, raw))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                } else {
                    let raw = window.rawSampleCount ?? 0
                    Text("Not enough data yet (\(raw) events)")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            Spacer()

            if !window.hasData {
                Button {
                    Task { await runIsfExperimentNow() }
                } label: {
                    Text("Run test")
                        .font(.caption.weight(.medium))
                        .padding(.horizontal, 10).padding(.vertical, 5)
                        .background(Color.purple.opacity(0.15))
                        .foregroundStyle(.purple)
                        .clipShape(Capsule())
                }
                .buttonStyle(.plain)
            }
        }
    }

    // MARK: - Helpers

    private func barColor(for window: String) -> Color {
        switch window {
        case "BREAKFAST": return .orange
        case "LUNCH":     return .blue
        case "DINNER":    return .indigo
        default:          return .purple
        }
    }

    private func load() async {
        guard profile == nil else { return }
        await fetch(forceRecompute: false)
    }

    private func recompute() async {
        await fetch(forceRecompute: true)
    }

    private func fetch(forceRecompute: Bool) async {
        isLoading = true
        bannerError = nil
        defer { isLoading = false }
        do {
            profile = forceRecompute
                ? try await BackendAPI.recomputeIsfMealWindows()
                : try await BackendAPI.fetchIsfMealWindows()
        } catch {
            bannerError = .fromLoad(error)
        }
    }

    private func runIsfExperimentNow() async {
        do {
            try await experimentVM.startExperiment(type: .isfOneUnit)
        } catch {
            bannerError = .fromAction(error, action: "start the ISF test")
        }
    }
}

// MARK: - Banner model

/// Tagged error model for the chart card. Knows where the error came from so the banner
/// can show an accurate title, and parses the backend's standard Spring error envelope
/// (`{status, error, message, path, timestamp}`) so users see just the {@code message}
/// instead of the raw JSON.
struct BannerError: Identifiable {
    enum Kind {
        case load                      // failed to fetch / recompute the cached profile
        case action(String)            // failed during a user action — verb (e.g. "start the ISF test")
    }

    let id = UUID()
    let kind: Kind
    let httpStatus: Int?
    let message: String                // user-facing reason, parsed from server payload when possible

    var title: String {
        switch kind {
        case .load:                return "Couldn't load your ISF profile"
        case .action(let verb):    return "Couldn't \(verb)"
        }
    }

    var icon: String {
        switch httpStatus {
        case 409:           return "lock.shield"        // conflict — precondition not met
        case .some(401),
             .some(403):    return "person.crop.circle.badge.exclamationmark"
        case .some(let s) where (500..<600).contains(s):
                            return "exclamationmark.icloud"
        default:            return "exclamationmark.triangle"
        }
    }

    static func fromLoad(_ error: Error) -> BannerError {
        let parsed = parse(error)
        return BannerError(kind: .load, httpStatus: parsed.status, message: parsed.message)
    }

    static func fromAction(_ error: Error, action verb: String) -> BannerError {
        let parsed = parse(error)
        return BannerError(kind: .action(verb), httpStatus: parsed.status, message: parsed.message)
    }

    /// Best-effort parse of `APIError.httpStatus(code, body)` — extracts the Spring
    /// envelope's {@code message} field, falling back to the body or the localised
    /// description.
    private static func parse(_ error: Error) -> (status: Int?, message: String) {
        if let api = error as? GlucoseMonitorAPI.APIError,
           case .httpStatus(let code, let body) = api {
            let message = extractMessage(from: body) ?? body ?? "The server didn't return a reason."
            return (code, message)
        }
        return (nil, error.localizedDescription)
    }

    /// Decodes Spring's `{ "status":…, "error":…, "message":…, "path":…, "timestamp":… }`
    /// envelope and returns the `message`. Returns nil if the body isn't that shape.
    private static func extractMessage(from body: String?) -> String? {
        guard let body, let data = body.data(using: .utf8) else { return nil }
        struct Envelope: Decodable { let message: String? }
        if let env = try? JSONDecoder().decode(Envelope.self, from: data),
           let msg = env.message, !msg.isEmpty {
            return msg
        }
        return nil
    }
}

// MARK: - Banner view

/// Designed inline error banner. Soft tinted background, status-specific icon, title,
/// and the parsed server message. Tap the chevron to dismiss.
struct ErrorBanner: View {
    let error: BannerError
    let onDismiss: () -> Void

    private var tint: Color {
        switch error.httpStatus {
        case 409: return .orange
        case .some(401), .some(403): return .red
        case .some(let s) where (500..<600).contains(s): return .red
        default: return .orange
        }
    }

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: error.icon)
                .font(.title3)
                .foregroundStyle(tint)
                .frame(width: 22)

            VStack(alignment: .leading, spacing: 4) {
                Text(error.title)
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(.primary)
                Text(error.message)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Spacer(minLength: 4)

            Button(action: onDismiss) {
                Image(systemName: "xmark")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
                    .padding(6)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Dismiss")
        }
        .padding(12)
        .background(tint.opacity(0.12))
        .overlay(
            RoundedRectangle(cornerRadius: 12)
                .strokeBorder(tint.opacity(0.35), lineWidth: 1)
        )
        .clipShape(RoundedRectangle(cornerRadius: 12))
    }
}
