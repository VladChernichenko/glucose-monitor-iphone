import SwiftUI
import ARKit
import SceneKit

// MARK: - AR Scene View bridge

/// Wraps ARSCNView (UIKit) for SwiftUI. The view renders the live camera feed
/// with AR overlays. Feature-point cloud visualisation is left to ARKit defaults.
struct ARSceneViewWrapper: UIViewRepresentable {

    let session: ARFoodScannerSession

    func makeUIView(context: Context) -> ARSCNView {
        let arView = ARSCNView()
        arView.session = session.arSession
        arView.automaticallyUpdatesLighting = true
        arView.showsStatistics = false
        // Show feature points so the user can see where SLAM is tracking
        arView.debugOptions = [.showFeaturePoints]
        arView.antialiasingMode = .multisampling2X
        return arView
    }

    func updateUIView(_ uiView: ARSCNView, context: Context) {
        // session changes are managed by ARFoodScannerSession directly
    }
}

// MARK: - Main AR food scanner view

/// Full-screen AR view that guides the user through:
///   1. Slow scan (move phone around the plate to accumulate feature points)
///   2. Tap "Analyse" to trigger RANSAC + volume pipeline
///   3. Display the FoodVolumeReport as a result card
struct ARFoodScannerView: View {

    /// Called with the final volume report so the parent can convert it
    /// to a NutritionSnapshot and proceed to note creation.
    let onResult: (FoodVolumeReport) -> Void
    let onDismiss: () -> Void

    @StateObject private var scanner = ARFoodScannerSession()

    var body: some View {
        ZStack {
            // ── AR camera feed ──────────────────────────────────────────────
            ARSceneViewWrapper(session: scanner)
                .ignoresSafeArea()

            // ── Overlay UI ─────────────────────────────────────────────────
            VStack {
                statusBanner
                    .padding(.top, 60)

                Spacer()

                bottomControls
                    .padding(.bottom, 48)
            }
        }
        .onAppear { scanner.start() }
        .onDisappear { scanner.stop() }
        .onChange(of: scanner.scanState) { state in
            if case .done(let report) = state {
                onResult(report)
            }
        }
    }

    // MARK: Status banner

    @ViewBuilder
    private var statusBanner: some View {
        switch scanner.scanState {

        case .idle:
            guidancePill("Point at food to begin", icon: "camera", color: .gray)

        case .scanning(let count):
            let ready = count >= 80
            guidancePill(
                ready
                    ? "Good coverage — tap Analyse when ready"
                    : "Move slowly around the food (\(count) pts)",
                icon: ready ? "checkmark.circle" : "arrow.triangle.2.circlepath",
                color: ready ? .green : .orange
            )

        case .analyzing:
            HStack(spacing: 12) {
                ProgressView().tint(.white)
                Text("Analysing volume…")
                    .font(.callout.bold())
                    .foregroundStyle(.white)
            }
            .padding(.horizontal, 20).padding(.vertical, 10)
            .background(.ultraThinMaterial, in: Capsule())

        case .done:
            guidancePill("Done!", icon: "checkmark.seal.fill", color: .green)

        case .failed(let msg):
            guidancePill(msg, icon: "exclamationmark.triangle", color: .red)
        }
    }

    private func guidancePill(_ text: String, icon: String, color: Color) -> some View {
        Label(text, systemImage: icon)
            .font(.callout.bold())
            .foregroundStyle(.white)
            .padding(.horizontal, 18).padding(.vertical, 10)
            .background(color.opacity(0.85), in: Capsule())
            .shadow(radius: 4)
    }

    // MARK: Bottom controls

    @ViewBuilder
    private var bottomControls: some View {
        HStack(spacing: 32) {
            // Cancel
            Button {
                onDismiss()
            } label: {
                Label("Cancel", systemImage: "xmark")
                    .font(.callout.bold())
                    .foregroundStyle(.white)
                    .padding(.horizontal, 20).padding(.vertical, 12)
                    .background(.ultraThinMaterial, in: Capsule())
            }

            // Analyse / retry
            if case .scanning(let count) = scanner.scanState {
                Button {
                    scanner.analyzeCurrentFrame()
                } label: {
                    Label("Analyse", systemImage: "cube.transparent")
                        .font(.headline.bold())
                        .foregroundStyle(.white)
                        .padding(.horizontal, 28).padding(.vertical, 14)
                        .background(count >= 80 ? Color.blue : Color.blue.opacity(0.4),
                                    in: Capsule())
                }
                .disabled(count < 80)
            } else if case .failed = scanner.scanState {
                Button {
                    scanner.start()
                } label: {
                    Label("Retry", systemImage: "arrow.clockwise")
                        .font(.headline.bold())
                        .foregroundStyle(.white)
                        .padding(.horizontal, 28).padding(.vertical, 14)
                        .background(Color.orange, in: Capsule())
                }
            }
        }
    }
}

// MARK: - Result card (shown in FoodScanSheet after AR analysis)

struct ARVolumeResultCard: View {
    let report: FoodVolumeReport

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Label("AR Volume Scan", systemImage: "cube.transparent.fill")
                .font(.headline)
                .foregroundStyle(.blue)

            if report.detectedObjects.isEmpty {
                Text("No food detected above the plate — try rescanning.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            } else {
                ForEach(report.detectedObjects, id: \.label) { item in
                    HStack {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(item.label)
                                .font(.callout.bold())
                            Text("\(item.volumeCm3, format: .number.precision(.fractionLength(1))) cm³")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                        Spacer()
                        VStack(alignment: .trailing, spacing: 2) {
                            Text("\(item.estimatedMassG, format: .number.precision(.fractionLength(0))) g")
                                .font(.callout.bold())
                                .foregroundStyle(.primary)
                            Text("≈ mass")
                                .font(.caption2)
                                .foregroundStyle(.tertiary)
                        }
                    }
                    .padding(.vertical, 6)
                    .padding(.horizontal, 12)
                    .background(.quaternary, in: RoundedRectangle(cornerRadius: 10))
                }
            }

            // Confidence indicator
            HStack(spacing: 6) {
                Image(systemName: "point.3.connected.trianglepath.dotted")
                    .foregroundStyle(.secondary)
                Text("Point coverage: \(report.segmentedPointRatio * 100, format: .number.precision(.fractionLength(0)))%")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Spacer()
                Text("Plane error: \(report.planeRmsM * 100, format: .number.precision(.fractionLength(1))) mm")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(16)
        .background(.thinMaterial, in: RoundedRectangle(cornerRadius: 16))
    }
}

// MARK: - Helpers: FoodVolumeReport → note text

extension FoodVolumeReport {
    /// Build a human-readable food description for backend nutrition analysis.
    /// Format: "гречка 120g, котлета 95g"
    var noteDescription: String {
        detectedObjects
            .map { "\($0.label) \(Int($0.estimatedMassG))g" }
            .joined(separator: ", ")
    }

    /// Total estimated meal mass in grams
    var totalMassG: Double {
        detectedObjects.reduce(0) { $0 + $1.estimatedMassG }
    }
}
