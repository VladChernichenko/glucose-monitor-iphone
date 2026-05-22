import SwiftUI
import ARKit
import SceneKit
import Vision

// MARK: - ARKit Scene View Bridge

struct ARSceneViewWrapper: UIViewRepresentable {
    let session: ARSession

    func makeUIView(context: Context) -> ARSCNView {
        let v = ARSCNView()
        v.session = session
        v.automaticallyUpdatesLighting = true
        v.showsStatistics = false
        v.debugOptions = [.showFeaturePoints]
        v.antialiasingMode = .multisampling2X
        return v
    }
    func updateUIView(_ uiView: ARSCNView, context: Context) {}
}

// MARK: - Main AR Capture View

/// Full-screen AR view that:
///   1. Streams the live camera + LiDAR feed.
///   2. On "Capture" tap: runs FoodSegModel → depth integration → local nutrition lookup.
///   3. Calls `onResult` with the complete `NutrientSummary`.
struct ARFoodScannerView: View {
    let onResult:  (NutrientSummary) -> Void
    let onDismiss: () -> Void

    @StateObject private var sessionMgr = ARSessionManager()
    @State private var isProcessing = false
    @State private var processingMsg = ""

    private let recognizer   = try? FoodRecognitionService()
    private let nutritionSvc = NutritionAPIService()

    var body: some View {
        ZStack {
            ARSceneViewWrapper(session: sessionMgr.arSession).ignoresSafeArea()

            VStack {
                statusBanner.padding(.top, 60)
                Spacer()
                bottomControls.padding(.bottom, 48)
            }

            if isProcessing { processingOverlay }
        }
        .onAppear    { sessionMgr.start() }
        .onDisappear { sessionMgr.stop() }
    }

    // MARK: Status Banner

    @ViewBuilder private var statusBanner: some View {
        let (icon, text, color): (String, String, Color) = {
            switch sessionMgr.scanState {
            case .idle:
                return ("camera", "Point at food to begin", .gray)
            case .capturing:
                let note = sessionMgr.isLiDARAvailable ? "LiDAR active" : "No LiDAR — use flat surface"
                return ("viewfinder", "Hold steady · \(note)", .green)
            case .processingVision:
                return ("cpu", "Detecting food items…", .blue)
            case .verifyingWithQwen:
                return ("checkmark.shield", "Verifying with Qwen…", .indigo)
            case .fetchingNutrition(let p, let t):
                return ("network", "Nutrition \(p)/\(t)…", .blue)
            case .done:
                return ("checkmark.seal.fill", "Done!", .green)
            case .failed(let m):
                return ("exclamationmark.triangle", m, .red)
            }
        }()

        Label(text, systemImage: icon)
            .font(.callout.bold()).foregroundStyle(.white)
            .padding(.horizontal, 18).padding(.vertical, 10)
            .background(color.opacity(0.85), in: Capsule())
            .shadow(radius: 4)
    }

    // MARK: Bottom Controls

    @ViewBuilder private var bottomControls: some View {
        HStack(spacing: 32) {
            Button { onDismiss() } label: {
                Label("Cancel", systemImage: "xmark")
                    .font(.callout.bold()).foregroundStyle(.white)
                    .padding(.horizontal, 20).padding(.vertical, 12)
                    .background(.ultraThinMaterial, in: Capsule())
            }

            switch sessionMgr.scanState {
            case .capturing:
                Button { captureAndProcess() } label: {
                    Label("Capture", systemImage: "camera.fill")
                        .font(.headline.bold()).foregroundStyle(.white)
                        .padding(.horizontal, 28).padding(.vertical, 14)
                        .background(Color.blue, in: Capsule())
                }
                .disabled(isProcessing)

            case .failed:
                Button { sessionMgr.start() } label: {
                    Label("Retry", systemImage: "arrow.clockwise")
                        .font(.headline.bold()).foregroundStyle(.white)
                        .padding(.horizontal, 28).padding(.vertical, 14)
                        .background(Color.orange, in: Capsule())
                }

            default: EmptyView()
            }
        }
    }

    private var processingOverlay: some View {
        ZStack {
            Color.black.opacity(0.5).ignoresSafeArea()
            VStack(spacing: 16) {
                ProgressView().tint(.white).scaleEffect(1.4)
                Text(processingMsg).font(.callout.bold()).foregroundStyle(.white)
                    .multilineTextAlignment(.center).padding(.horizontal, 32)
            }
        }
    }

    // MARK: Capture & Pipeline

    private func captureAndProcess() {
        guard let frame = sessionMgr.captureCurrentFrame() else {
            sessionMgr.scanState = .failed("No frame yet — point at food and retry.")
            return
        }
        isProcessing = true
        processingMsg = "Running food segmentation…"
        Task { await runPipeline(frame: frame) }
    }

    @MainActor
    private func runPipeline(frame: ARFrame) async {
        defer { isProcessing = false }

        sessionMgr.scanState = .processingVision
        let imgSize = CGSize(width:  CVPixelBufferGetWidth(frame.capturedImage),
                             height: CVPixelBufferGetHeight(frame.capturedImage))

        // ── Step 1: Segmentation ──────────────────────────────────────────────
        // Primary path: FoodSegModel CoreML (instance segmentation with pixel masks).
        // Fallback:     VNClassifyImageRequest (Apple built-in, no custom model needed).
        //               Produces a whole-image mask per detected food label — volume
        //               is integrated over the full plate region, still useful for
        //               density → mass → local nutrition lookup.
        let segments: [SegmentationResult]
        if let svc = recognizer {
            do {
                segments = try await svc.recognize(pixelBuffer: frame.capturedImage, imageSize: imgSize)
            } catch {
                sessionMgr.scanState = .failed("Segmentation: \(error.localizedDescription)")
                return
            }
        } else {
            // FoodSegModel not bundled — fall back to Vision classifier.
            segments = await classifyWithVision(pixelBuffer: frame.capturedImage, imageSize: imgSize)
        }

        guard !segments.isEmpty else {
            sessionMgr.scanState = .failed("No food detected. Move closer and retry.")
            return
        }

        // ── Step 1.5: Qwen double-check ───────────────────────────────────────
        // Send the captured frame to the backend (Qwen-VL) and reconcile labels.
        // On any failure we silently keep the raw YOLO results.
        let verifiedSegments: [SegmentationResult]
        if let uiImage = UIImage(cvPixelBuffer: frame.capturedImage) {
            sessionMgr.scanState = .verifyingWithQwen
            processingMsg = "Verifying with Qwen…"
            do {
                let snap = try await BackendAPI.analyzePhotoNutrition(image: uiImage)
                let qwenFoods = snap.normalizedFoods ?? []
                verifiedSegments = qwenFoods.isEmpty
                    ? segments
                    : reconcileWithQwen(yolo: segments, qwenFoods: qwenFoods, imageSize: imgSize)
            } catch {
                // Qwen unavailable or timed out — proceed with YOLO labels
                verifiedSegments = segments
            }
        } else {
            verifiedSegments = segments
        }

        // ── Step 2: Volume → Mass → Nutrition per segment ─────────────────────
        let depthMap   = frame.sceneDepth?.depthMap
        let intrinsics = frame.camera.intrinsics
        var components: [FoodComponent] = []

        // Group segments by label: sum volumes and union bounding boxes so that
        // multiple detections of the same food (e.g. 4 strawberries) appear as one item.
        var groupedVolume: [String: Double] = [:]
        var groupedBBox:   [String: CGRect] = [:]
        for seg in verifiedSegments {
            let volumeCm3: Double
            if let depth = depthMap {
                volumeCm3 = VolumeCalculator.volume(for: seg, depthMap: depth,
                                                    intrinsics: intrinsics,
                                                    imageSize: imgSize)
            } else {
                let areaFrac = seg.boundingBox.width * seg.boundingBox.height
                volumeCm3 = Double(areaFrac) * 1200.0
            }
            groupedVolume[seg.label, default: 0] += volumeCm3
            groupedBBox[seg.label] = groupedBBox[seg.label]
                .map { $0.union(seg.boundingBox) } ?? seg.boundingBox
        }

        // Cross-label deduplication: two groups whose bounding boxes overlap by more
        // than 25 % almost certainly detected the same physical item with different class
        // labels (e.g. "biscuit" + "bread" for one bread slice).  Keep only the group
        // whose estimated volume is larger (better signal); discard the smaller one.
        let groupLabels = Array(groupedVolume.keys)
        var suppressedLabels = Set<String>()
        for i in 0..<groupLabels.count {
            guard !suppressedLabels.contains(groupLabels[i]) else { continue }
            let boxA = groupedBBox[groupLabels[i]] ?? .zero
            let volA = groupedVolume[groupLabels[i]] ?? 0
            for j in (i + 1)..<groupLabels.count {
                guard !suppressedLabels.contains(groupLabels[j]) else { continue }
                let boxB = groupedBBox[groupLabels[j]] ?? .zero
                let volB = groupedVolume[groupLabels[j]] ?? 0
                let inter = boxA.intersection(boxB)
                guard !inter.isNull else { continue }
                let interArea = inter.width * inter.height
                let unionArea = boxA.width * boxA.height + boxB.width * boxB.height - interArea
                let overlapIou = unionArea > 0 ? interArea / unionArea : CGFloat(0)
                if overlapIou > 0.25 {
                    // Suppress the lower-volume (less confident) group.
                    suppressedLabels.insert(volA >= volB ? groupLabels[j] : groupLabels[i])
                }
            }
        }
        for label in suppressedLabels {
            groupedVolume.removeValue(forKey: label)
            groupedBBox.removeValue(forKey: label)
        }

        sessionMgr.scanState = .fetchingNutrition(progress: 0, total: groupedVolume.count)

        for (idx, (label, totalVolume)) in groupedVolume.enumerated() {
            processingMsg = "Fetching nutrition for \(label)…"
            sessionMgr.scanState = .fetchingNutrition(progress: idx + 1,
                                                       total: groupedVolume.count)

            let density = DensityMapper.density(for: label)
            let massG   = totalVolume * density
            guard massG > 1.0 else { continue }  // filter noise

            let bbox      = groupedBBox[label] ?? CGRect(x: 0.2, y: 0.2, width: 0.6, height: 0.6)
            let nutrients = nutritionSvc.fetchNutrition(label: label, massG: massG)

            components.append(FoodComponent(
                label: label,
                massG: massG.rounded(toPlaces: 1),
                volumeCm3: totalVolume.rounded(toPlaces: 1),
                densityGCm3: density,
                boundingBox: bbox,
                nutrients: nutrients
            ))
        }

        guard !components.isEmpty else {
            sessionMgr.scanState = .failed("Volume too small to measure. Move closer.")
            return
        }

        // ── Step 3: Build summary ─────────────────────────────────────────────
        guard let uiImage = UIImage(cvPixelBuffer: frame.capturedImage) else {
            sessionMgr.scanState = .failed("Failed to capture preview image.")
            return
        }
        let summary = NutrientSummary(components: components,
                                      capturedImage: uiImage,
                                      capturedAt: Date())
        sessionMgr.scanState = .done(summary)
        onResult(summary)
    }

    // MARK: Qwen double-check reconciliation

    /// Merges YOLO segments with Qwen-VL food names.
    /// - Corrects YOLO labels when Qwen identifies a better name.
    /// - Adds synthetic segments for foods Qwen found that YOLO missed entirely.
    private func reconcileWithQwen(
        yolo: [SegmentationResult],
        qwenFoods: [String],
        imageSize: CGSize
    ) -> [SegmentationResult] {
        var result: [SegmentationResult] = []
        var matchedQwenIndices = Set<Int>()

        for seg in yolo {
            if let (idx, correctedLabel) = bestQwenMatch(for: seg.label, in: qwenFoods) {
                matchedQwenIndices.insert(idx)
                result.append(SegmentationResult(
                    label: correctedLabel,
                    confidence: seg.confidence,
                    boundingBox: seg.boundingBox,
                    pixelMask: seg.pixelMask,
                    maskWidth: seg.maskWidth,
                    maskHeight: seg.maskHeight,
                    imageSize: seg.imageSize
                ))
            } else {
                result.append(seg)
            }
        }

        // Add foods Qwen found that YOLO completely missed.
        // Use a centered default bbox; volume/mass will be estimated via LiDAR or area heuristic.
        let w = Int(imageSize.width), h = Int(imageSize.height)
        let defaultMask = [Bool](repeating: true, count: w * h)
        for (idx, food) in qwenFoods.enumerated() where !matchedQwenIndices.contains(idx) {
            result.append(SegmentationResult(
                label: food,
                confidence: 0.55,
                boundingBox: CGRect(x: 0.25, y: 0.25, width: 0.5, height: 0.5),
                pixelMask: defaultMask,
                maskWidth: w,
                maskHeight: h,
                imageSize: imageSize
            ))
        }
        return result
    }

    /// Returns the Qwen food name that best matches a YOLO label, or nil if no match.
    private func bestQwenMatch(for yoloLabel: String, in qwenFoods: [String]) -> (Int, String)? {
        let lower = yoloLabel.lowercased()
        for (idx, food) in qwenFoods.enumerated() {
            let f = food.lowercased()
            if f == lower || f.contains(lower) || lower.contains(f) {
                return (idx, food)
            }
            let yWords = lower.split(separator: " ").filter { $0.count > 3 }.map(String.init)
            let qWords = f.split(separator: " ").filter { $0.count > 3 }.map(String.init)
            if yWords.contains(where: { qWords.contains($0) }) {
                return (idx, food)
            }
        }
        return nil
    }

    // MARK: Vision classifier fallback (no custom CoreML model required)
    //
    // Uses Apple's VNClassifyImageRequest (~1000 categories including most foods).
    // Returns up to 3 deduplicated food classifications, each backed by a whole-image
    // mask. Labels are normalized (underscores → spaces) and grouped by their base food
    // word so that "food", "bread", and "white bread" don't all map to separate items.
    private func classifyWithVision(pixelBuffer: CVPixelBuffer,
                                    imageSize: CGSize) async -> [SegmentationResult] {
        await withCheckedContinuation { continuation in
            let request = VNClassifyImageRequest { req, _ in
                let foodKeywords = ["bread","pasta","rice","pizza","burger","sandwich",
                                    "sushi","noodle","cheese","porridge","pancake",
                                    "stew","curry","chicken","beef","pork","fish",
                                    "salmon","egg","soup","salad","fruit","vegetable",
                                    "meat","dish","meal","food"]

                let candidates = (req.results as? [VNClassificationObservation] ?? [])
                    .filter { $0.confidence > 0.20 }
                    .sorted { $0.confidence > $1.confidence }

                // Normalize identifier: underscores → spaces, take first comma-segment.
                func normalize(_ id: String) -> String {
                    id.replacingOccurrences(of: "_", with: " ")
                      .components(separatedBy: ",").first?
                      .trimmingCharacters(in: .whitespaces)
                      .lowercased() ?? id.lowercased()
                }

                // Group by base food word; keep only the highest-confidence label per group.
                // "white bread" and "bread" both map to group "bread" → one item retained.
                var grouped: [String: VNClassificationObservation] = [:]
                for obs in candidates {
                    let label = normalize(obs.identifier)
                    // Find which food keyword this label belongs to (most specific wins).
                    guard let group = foodKeywords.first(where: { label.contains($0) }) else { continue }
                    // Skip the catch-all "food" group if any specific group is already present.
                    if group == "food" && !grouped.isEmpty { continue }
                    if grouped[group] == nil { grouped[group] = obs }
                }

                // Keep up to 3 most-confident unique groups (drop "food" if others exist).
                let deduped = grouped
                    .filter { grouped.count == 1 || $0.key != "food" }
                    .sorted { $0.value.confidence > $1.value.confidence }
                    .prefix(3)
                    .map { $0.value }

                guard !deduped.isEmpty else { continuation.resume(returning: []); return }

                let w = Int(imageSize.width), h = Int(imageSize.height)
                let allPixels = [Bool](repeating: true, count: w * h)

                let results: [SegmentationResult] = deduped.enumerated().map { idx, o in
                    let label = normalize(o.identifier)
                    let sliceH = 1.0 / Double(deduped.count)
                    let bbox = CGRect(x: 0, y: sliceH * Double(idx),
                                     width: 1.0, height: sliceH)
                    return SegmentationResult(label: label, confidence: o.confidence,
                                              boundingBox: bbox, pixelMask: allPixels,
                                              maskWidth: w, maskHeight: h, imageSize: imageSize)
                }
                continuation.resume(returning: results)
            }
            do {
                try VNImageRequestHandler(cvPixelBuffer: pixelBuffer,
                                          orientation: .up, options: [:]).perform([request])
            } catch {
                continuation.resume(returning: [])
            }
        }
    }
}

// MARK: - Nutrient Summary View

/// Full results screen: captured photo with bounding-box overlays + nutrition breakdown.
struct NutrientSummaryView: View {
    let summary: NutrientSummary

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                imageWithOverlays
                totalPlateCard
                VStack(alignment: .leading, spacing: 10) {
                    Text("Breakdown").font(.headline).padding(.horizontal)
                    ForEach(summary.components) { FoodComponentCard(component: $0).padding(.horizontal) }
                }
            }
            .padding(.vertical)
        }
        .navigationTitle("Nutrition Analysis")
        .navigationBarTitleDisplayMode(.inline)
    }

    // Captured image with bounding-box and label overlays.
    private var imageWithOverlays: some View {
        GeometryReader { geo in
            let imgW = geo.size.width
            let imgH = imgW * (summary.capturedImage.size.height / summary.capturedImage.size.width)
            ZStack(alignment: .topLeading) {
                Image(uiImage: summary.capturedImage)
                    .resizable().scaledToFit().frame(width: imgW).cornerRadius(12)
                ForEach(summary.components) { comp in
                    let b = comp.boundingBox
                    RoundedRectangle(cornerRadius: 4).stroke(Color.yellow, lineWidth: 2)
                        .frame(width: b.width * imgW, height: b.height * imgH)
                        .offset(x: b.minX * imgW, y: b.minY * imgH)
                    Text(comp.label.capitalized).font(.caption2.bold()).foregroundStyle(.yellow)
                        .padding(3)
                        .background(Color.black.opacity(0.65), in: RoundedRectangle(cornerRadius: 4))
                        .offset(x: b.minX * imgW, y: max(0, b.minY * imgH - 20))
                }
            }
        }
        .aspectRatio(summary.capturedImage.size, contentMode: .fit)
        .padding(.horizontal)
    }

    private var totalPlateCard: some View {
        VStack(alignment: .leading, spacing: 12) {
            Label("Total Plate Summary", systemImage: "chart.pie.fill")
                .font(.headline).foregroundStyle(.blue)
            LazyVGrid(columns: Array(repeating: GridItem(.flexible()), count: 2), spacing: 10) {
                MetricTile(title: "Calories",      value: "\(Int(summary.totalCalories)) kcal",           icon: "flame.fill",         color: .orange)
                MetricTile(title: "Glycemic Load", value: String(format: "%.1f", summary.totalGL),        icon: "waveform.path.ecg",  color: .red)
                MetricTile(title: "Carbs",         value: String(format: "%.0fg", summary.totalCarbsG),   icon: "leaf.fill",          color: .green)
                MetricTile(title: "Protein",       value: String(format: "%.0fg", summary.totalProteinG), icon: "bolt.fill",          color: .blue)
                MetricTile(title: "Fat",           value: String(format: "%.0fg", summary.totalFatG),     icon: "drop.fill",          color: .purple)
                MetricTile(title: "Items",         value: "\(summary.components.count)",                  icon: "fork.knife",         color: .secondary)
            }
        }
        .padding(16)
        .background(.thinMaterial, in: RoundedRectangle(cornerRadius: 16))
        .padding(.horizontal)
    }
}

// MARK: - Compact Scan Card (for NoteEditorSheet)

/// Compact nutrition card used inside `NoteEditorSheet`.
struct NutrientScanCard: View {
    let summary: NutrientSummary

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Label("AR Nutrition Scan", systemImage: "cube.transparent.fill")
                .font(.headline).foregroundStyle(.blue)

            if summary.components.isEmpty {
                Text("No food detected above the plate — try rescanning.")
                    .font(.callout).foregroundStyle(.secondary)
            } else {
                ForEach(summary.components) { comp in
                    HStack {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(comp.label.capitalized).font(.callout.bold())
                            Text("\(Int(comp.massG.rounded()))g · \(Int(comp.volumeCm3.rounded())) cm³")
                                .font(.caption).foregroundStyle(.secondary)
                        }
                        Spacer()
                        if let n = comp.nutrients {
                            VStack(alignment: .trailing, spacing: 2) {
                                Text("\(Int(n.calories.rounded())) kcal").font(.callout.bold())
                                if let gl = n.glycemicLoad {
                                    Text("GL \(String(format: "%.1f", gl))").font(.caption.bold())
                                        .foregroundStyle(gl < 10 ? .green : gl < 20 ? .orange : .red)
                                }
                            }
                        }
                    }
                    .padding(.vertical, 6).padding(.horizontal, 12)
                    .background(.quaternary, in: RoundedRectangle(cornerRadius: 10))
                }
            }

            HStack(spacing: 6) {
                Image(systemName: "scalemass").foregroundStyle(.secondary)
                Text("Total: \(Int(summary.components.map(\.massG).reduce(0,+).rounded()))g")
                    .font(.caption).foregroundStyle(.secondary)
                Spacer()
                if let gi = summary.averageGI {
                    Text("Avg GI: \(Int(gi.rounded()))").font(.caption).foregroundStyle(.secondary)
                }
            }
        }
        .padding(16)
        .background(.thinMaterial, in: RoundedRectangle(cornerRadius: 16))
    }
}

// MARK: - Per-food Component Card

struct FoodComponentCard: View {
    let component: FoodComponent

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text(component.label.capitalized).font(.callout.bold())
                    Text("\(Int(component.massG.rounded()))g · \(Int(component.volumeCm3.rounded())) cm³")
                        .font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
                if let n = component.nutrients {
                    VStack(alignment: .trailing, spacing: 2) {
                        Text("\(Int(n.calories.rounded())) kcal")
                            .font(.callout.bold()).foregroundStyle(.orange)
                        if let gl = n.glycemicLoad {
                            Text("GL \(String(format: "%.1f", gl))").font(.caption.bold())
                                .foregroundStyle(gl < 10 ? .green : gl < 20 ? .orange : .red)
                        }
                    }
                }
            }
            if let n = component.nutrients {
                HStack(spacing: 14) {
                    NutrientPill(name: "Carbs",   value: n.carbsG,   color: .green)
                    NutrientPill(name: "Protein", value: n.proteinG, color: .blue)
                    NutrientPill(name: "Fat",     value: n.fatG,     color: .purple)
                    if let gi = n.glycemicIndex {
                        NutrientPill(name: "GI", value: gi, color: .red)
                    }
                }
            }
        }
        .padding(14)
        .background(.quaternary, in: RoundedRectangle(cornerRadius: 12))
    }
}

// MARK: - Shared Sub-views

private struct MetricTile: View {
    let title: String; let value: String; let icon: String; let color: Color
    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: icon).font(.title3).foregroundStyle(color).frame(width: 26)
            VStack(alignment: .leading, spacing: 1) {
                Text(title).font(.caption).foregroundStyle(.secondary)
                Text(value).font(.callout.bold())
            }
            Spacer()
        }
        .padding(10)
        .background(color.opacity(0.10), in: RoundedRectangle(cornerRadius: 10))
    }
}

private struct NutrientPill: View {
    let name: String; let value: Double; let color: Color
    var body: some View {
        VStack(spacing: 2) {
            Text(String(format: "%.0f", value)).font(.caption.bold()).foregroundStyle(color)
            Text(name).font(.caption2).foregroundStyle(.secondary)
        }
        .padding(.horizontal, 8).padding(.vertical, 4)
        .background(color.opacity(0.12), in: Capsule())
    }
}

// MARK: - Helpers

private extension UIImage {
    convenience init?(cvPixelBuffer: CVPixelBuffer) {
        let ci = CIImage(cvPixelBuffer: cvPixelBuffer)
        guard let cg = CIContext().createCGImage(ci, from: ci.extent) else { return nil }
        // ARKit delivers frames in landscape; .right rotates 90° clockwise so the
        // preview image appears upright when the phone is held in portrait.
        self.init(cgImage: cg, scale: 1.0, orientation: .right)
    }
}

extension Double {
    func rounded(toPlaces places: Int) -> Double {
        let f = pow(10.0, Double(places))
        return (self * f).rounded() / f
    }
}
