import SwiftUI

// MARK: - Root

struct WatchRootView: View {
    @ObservedObject private var session = WatchSessionReceiver.shared
    @Environment(\.scenePhase) private var scenePhase
    @State private var stored = GlanceStore.load()
    @State private var loading = false
    @State private var offline = false

    var body: some View {
        Group {
            if !session.isSignedIn {
                ConnectView { session.requestSessionIfNeeded() }
            } else if let stored {
                // Re-evaluated every 30 s so the age, greying and expired advice update without a fetch.
                TimelineView(.periodic(from: .now, by: 30)) { context in
                    GlanceView(
                        presentation: GlancePresentation(glance: stored.glance, now: context.date,
                                                         fetchedAt: stored.fetchedAt,
                                                         lastAttemptFailed: GlanceStore.lastAttemptFailed(),
                                                         unit: displayUnit),
                        offline: offline,
                        loading: loading,
                        onRefresh: { Task { await refresh() } }
                    )
                }
            } else {
                VStack(spacing: 8) {
                    ProgressView()
                    Text(offline ? "Can't reach the server" : "Loading…")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                    if offline {
                        Button("Try again") { Task { await refresh() } }
                    }
                }
            }
        }
        .task(id: session.generation) { await refresh() }
        .onChange(of: scenePhase) { _, phase in
            if phase == .active { Task { await refresh() } }
        }
        .onAppear { session.requestSessionIfNeeded() }
    }

    private var displayUnit: String {
        GlucoseMonitorAPI.sharedDefaults().string(forKey: GlucoseMonitorAPI.StorageKey.glucoseDisplayUnit) ?? "mmol/L"
    }

    @MainActor
    private func refresh() async {
        stored = GlanceStore.load()
        guard session.isSignedIn, !loading else { return }
        loading = true
        defer { loading = false }
        offline = !(await GlanceRefresher.refresh())
        stored = GlanceStore.load()
    }
}

// MARK: - Glance

private struct GlanceView: View {
    let presentation: GlancePresentation
    let offline: Bool
    let loading: Bool
    let onRefresh: () -> Void

    private var p: GlancePresentation { presentation }

    private var valueColor: Color {
        switch p.rangeColor {
        case .urgent: return .red
        case .low, .high: return .yellow
        case .inRange: return .green
        case .none: return .secondary
        }
    }

    var body: some View {
        ScrollView {
            VStack(spacing: 8) {
                VStack(spacing: 2) {
                    HStack(alignment: .firstTextBaseline, spacing: 4) {
                        Text(p.valueText)
                            .font(.system(size: 44, weight: .bold, design: .rounded))
                            .minimumScaleFactor(0.7)
                            .lineLimit(1)
                        Text(p.arrow)
                            .font(.title2)
                    }
                    .foregroundStyle(valueColor)

                    HStack(spacing: 3) {
                        Text(p.unitLabel)
                        if let at = p.readingAt {
                            Text("·")
                            Text(at, style: .relative)
                        }
                    }
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                }

                if let prediction = p.predictionText {
                    HStack(spacing: 4) {
                        Text("2h")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                        Text(prediction)
                            .font(.system(size: 20, weight: .semibold, design: .rounded))
                    }
                }

                if let stale = p.stale {
                    BannerView(banner: stale, tint: .orange)
                }
                if let strip = p.strip {
                    BannerView(banner: strip, tint: strip.urgent ? .red : .green)
                }

                if offline {
                    Text("Can't reach the server")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }

                Button(action: onRefresh) {
                    if loading {
                        ProgressView()
                    } else {
                        Label("Refresh", systemImage: "arrow.clockwise")
                            .font(.caption)
                    }
                }
                .disabled(loading)
            }
            .padding(.horizontal, 4)
        }
    }
}

/// The phone dashboard's banner: bold headline over one detail line, tinted.
private struct BannerView: View {
    let banner: GlancePresentation.Banner
    let tint: Color

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(banner.title)
                .font(.footnote.bold())
            if !banner.detail.isEmpty {
                Text(banner.detail)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(8)
        .background(tint.opacity(0.2))
        .clipShape(RoundedRectangle(cornerRadius: 10))
        .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(tint.opacity(0.5), lineWidth: 1))
        .accessibilityElement(children: .combine)
    }
}

// MARK: - Not connected

private struct ConnectView: View {
    let onRetry: () -> Void

    var body: some View {
        VStack(spacing: 10) {
            Image(systemName: "iphone.and.arrow.forward")
                .font(.title2)
                .foregroundStyle(.secondary)
            Text("Open the app on your iPhone to connect")
                .font(.caption2)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
            Button("Try again", action: onRetry)
                .font(.caption)
        }
        .padding()
    }
}
