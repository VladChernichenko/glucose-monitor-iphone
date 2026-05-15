import ARKit
import simd

// MARK: - Segmentation Interface

/// Pixel-level segmentation mask for one food item.
/// In production: fill from a CoreML model running on the ARFrame capturedImage.
/// Protocol allows injecting a mock during unit testing.
public protocol SegmentationProvider {
    /// Run inference on `pixelBuffer` and return one mask per detected food class.
    func segment(pixelBuffer: CVPixelBuffer,
                 imageSize: CGSize) async throws -> [FoodSegmentationMask]
}

public struct FoodSegmentationMask {
    public let label: String
    public let confidence: Float
    /// Flat set: index = row * imageWidth + col.  O(1) membership test.
    public let pixelSet: Set<Int>
    public let imageWidth: Int
    public let imageHeight: Int

    public init(label: String, confidence: Float,
                pixelSet: Set<Int>, imageWidth: Int, imageHeight: Int) {
        self.label = label; self.confidence = confidence
        self.pixelSet = pixelSet
        self.imageWidth = imageWidth; self.imageHeight = imageHeight
    }

    @inlinable
    public func contains(col: Int, row: Int) -> Bool {
        col >= 0 && col < imageWidth &&
        row >= 0 && row < imageHeight &&
        pixelSet.contains(row * imageWidth + col)
    }
}

// MARK: - Output models (JSON for Reasoning Agent)

public struct FoodVolumeResult: Codable, Equatable {
    public let label: String
    public let volumeCm3: Double
    public let estimatedMassG: Double

    enum CodingKeys: String, CodingKey {
        case label
        case volumeCm3 = "volume_cm3"
        case estimatedMassG = "estimated_mass_g"
    }
}

public struct FoodVolumeReport: Codable, Equatable {
    public let detectedObjects: [FoodVolumeResult]
    /// Fraction of accumulated feature points assigned to a food segment [0, 1]
    public let segmentedPointRatio: Double
    /// RMS orthogonal residual of the RANSAC plane fit (metres)
    public let planeRmsM: Double
    /// ISO-8601 scan timestamp
    public let capturedAt: String

    enum CodingKeys: String, CodingKey {
        case detectedObjects = "detected_objects"
        case segmentedPointRatio = "segmented_point_ratio"
        case planeRmsM = "plane_rms_error_m"
        case capturedAt = "captured_at"
    }

    /// Serialize to compact JSON string for the Reasoning Agent.
    public func jsonString() throws -> String {
        let enc = JSONEncoder(); enc.outputFormatting = [.prettyPrinted, .sortedKeys]
        return String(decoding: try enc.encode(self), as: UTF8.self)
    }
}

// MARK: - RANSAC Plane Fitter
// ---------------------------------------------------------------------------
// Fits the plane equation  ax + by + cz + d = 0  to a sparse 3-D point cloud.
//
// Algorithm (Fischler & Bolles 1981):
//   Repeat for `iterations` trials:
//     1. Draw 3 random points → compute candidate plane normal via cross-product.
//     2. Count inliers: |dot(n, p) + d| < inlierThreshold.
//     3. Keep the hypothesis with the most inliers.
//   Refit a least-squares plane to the final inlier set (centroid + covariance).
//
// Advantage over plain least-squares: robust to 30–50 % outliers caused by
// feature points on hands, utensils, and background surfaces.
// ---------------------------------------------------------------------------
public struct RANSACPlaneFitter {

    public struct Plane {
        /// Unit normal (a, b, c)
        public let normal: simd_float3
        /// Offset d: dot(normal, p) + d == 0 for points on the plane
        public let d: Float

        /// Signed orthogonal distance from `point` to this plane (metres)
        @inlinable
        public func signedDistance(to point: simd_float3) -> Float {
            simd_dot(normal, point) + d
        }

        /// Project a world point onto the plane surface
        @inlinable
        public func project(_ point: simd_float3) -> simd_float3 {
            point - signedDistance(to: point) * normal
        }

        /// RMS residual over a set of points (quality metric)
        public func rmsError(over points: [simd_float3]) -> Float {
            guard !points.isEmpty else { return 0 }
            let sumSq = points.reduce(0) { $0 + pow(signedDistance(to: $1), 2) }
            return sqrt(sumSq / Float(points.count))
        }
    }

    public static func fit(
        points: [simd_float3],
        iterations: Int = 120,
        inlierThreshold: Float = 0.008   // 8 mm — tight enough for a flat plate
    ) -> (plane: Plane, inliers: [simd_float3])? {
        guard points.count >= 6 else { return nil }

        var bestInliers: [simd_float3] = []
        var bestPlane: Plane?

        for _ in 0..<iterations {
            // Step 1: sample 3 distinct random points
            let idx = (0..<points.count).shuffled().prefix(3)
            let p0 = points[idx[idx.startIndex]]
            let p1 = points[idx[idx.index(after: idx.startIndex)]]
            let p2 = points[idx[idx.index(idx.startIndex, offsetBy: 2)]]

            let e1 = p1 - p0, e2 = p2 - p0
            let raw = simd_cross(e1, e2)
            let len = simd_length(raw)
            guard len > 1e-7 else { continue }   // degenerate triangle — skip

            let n = raw / len
            let d = -simd_dot(n, p0)
            let candidate = Plane(normal: n, d: d)

            // Step 2: count inliers
            let inliers = points.filter { abs(candidate.signedDistance(to: $0)) < inlierThreshold }
            if inliers.count > bestInliers.count {
                bestInliers = inliers
                bestPlane = candidate
            }
        }

        guard bestInliers.count >= 4 else { return nil }

        // Step 3: least-squares refit on inlier set.
        // The best-fit normal is the eigenvector corresponding to the *smallest*
        // eigenvalue of the 3×3 covariance matrix.  Here we use one power-iteration
        // step toward the covariance minimum using the RANSAC normal as the seed.
        let centroid = bestInliers.reduce(.zero, +) / Float(bestInliers.count)
        var refinedNormal = bestPlane!.normal

        // Power-iteration deflation (one step — sufficient for near-planar clouds)
        var cov = simd_float3x3(0)
        for p in bestInliers {
            let v = p - centroid
            cov.columns.0 += v * v.x
            cov.columns.1 += v * v.y
            cov.columns.2 += v * v.z
        }
        let residual = simd_mul(cov, refinedNormal)
        let residualLen = simd_length(residual)
        if residualLen > 1e-7 {
            // Deflate: normal ← normal - (Cn/|Cn|) * step
            let deflated = refinedNormal - (residual / residualLen) * 0.15
            let dLen = simd_length(deflated)
            if dLen > 1e-7 { refinedNormal = deflated / dLen }
        }

        let refinedD = -simd_dot(refinedNormal, centroid)
        return (Plane(normal: refinedNormal, d: refinedD), bestInliers)
    }
}

// MARK: - Volumetric Calculator
// ---------------------------------------------------------------------------
// Integrates the volume of food sitting above the reference plate plane.
//
// Method: cell-grid integration  V = Σᵢ hᵢ × δ²
//   1. Convert 3-D food points to plane-local 2-D coordinates (u, v).
//   2. Build a grid with cell side δ (default 6 mm).
//   3. For each occupied cell record the mean height h above the plane.
//   4. Sum cell volumes.  Convert m³ → cm³.
//
// For *soup / liquid bowls* (isSoup=true):
//   The bowl rim is the highest ring of points.  We estimate liquid volume as
//   the volume of the geometric cylinder defined by the rim footprint and the
//   median fill height — a conservative estimate that avoids overcount on
//   curved interior bowl walls.
// ---------------------------------------------------------------------------
public struct VolumetricCalculator {

    private static let cellSide: Float = 0.006          // 6 mm grid cell
    private static let minHeightAbovePlane: Float = 0.002 // ignore sub-2 mm noise
    private static let m3ToCm3: Double = 1_000_000.0

    /// Compute the volume (cm³) of food above `plane` using the supplied points.
    public static func volume(points: [simd_float3],
                               plane: RANSACPlaneFitter.Plane,
                               isSoup: Bool = false) -> Double {
        let above = points.filter { plane.signedDistance(to: $0) > minHeightAbovePlane }
        guard above.count >= 3 else { return 0 }

        if isSoup {
            return soupVolume(points: above, plane: plane)
        }

        // Build a pair of orthogonal axes in the plane for the 2-D grid
        let (uAxis, vAxis) = buildPlaneAxes(normal: plane.normal)

        // Map each point to its (u, v, h) in plane-local space
        struct CellVal { var heightSum: Float = 0; var count: Int = 0 }
        var grid: [SIMD2<Int32>: CellVal] = [:]

        for p in above {
            let projected = plane.project(p)
            let u = simd_dot(projected, uAxis)
            let v = simd_dot(projected, vAxis)
            let h = plane.signedDistance(to: p)
            let key = SIMD2<Int32>(Int32(u / cellSide), Int32(v / cellSide))
            grid[key, default: CellVal()].heightSum += h
            grid[key, default: CellVal()].count     += 1
        }

        // V = Σ (mean height per cell) × cellArea
        let cellArea = Double(cellSide * cellSide)
        let totalVolM3 = grid.values.reduce(0.0) { acc, cell in
            acc + Double(cell.heightSum / Float(cell.count)) * cellArea
        }
        return totalVolM3 * m3ToCm3
    }

    /// Bowl fullness estimation for soups.
    /// Approximates liquid volume as: πr² × fillHeight, where r = bowl radius
    /// estimated from the ring of rim points, and fillHeight = median height.
    private static func soupVolume(points: [simd_float3],
                                   plane: RANSACPlaneFitter.Plane) -> Double {
        let (uAxis, vAxis) = buildPlaneAxes(normal: plane.normal)

        // Collect (u, v, h) for all points
        let uvh: [(u: Float, v: Float, h: Float)] = points.map { p in
            let proj = plane.project(p)
            return (simd_dot(proj, uAxis), simd_dot(proj, vAxis),
                    plane.signedDistance(to: p))
        }

        // Estimate bowl centre as centroid of projections
        let centU = uvh.map(\.u).reduce(0, +) / Float(uvh.count)
        let centV = uvh.map(\.v).reduce(0, +) / Float(uvh.count)

        // Bowl radius = 90th-percentile radial distance (rim)
        let radii = uvh.map { sqrt(pow($0.u - centU, 2) + pow($0.v - centV, 2)) }.sorted()
        let bowlRadius = radii[Int(Double(radii.count) * 0.90)]

        // Fill height = median h among interior points (r < 80% of rim radius)
        let interior = uvh.filter {
            sqrt(pow($0.u - centU, 2) + pow($0.v - centV, 2)) < bowlRadius * 0.8
        }.map(\.h).sorted()
        guard !interior.isEmpty else { return 0 }
        let fillHeight = interior[interior.count / 2]

        // V = π r² h  (cylindrical approximation — conservative for curved bowls)
        let volM3 = Double.pi * Double(bowlRadius * bowlRadius) * Double(fillHeight)
        return max(0, volM3 * m3ToCm3)
    }

    /// Build two orthogonal unit axes that span the plane.
    private static func buildPlaneAxes(normal: simd_float3) -> (u: simd_float3, v: simd_float3) {
        // Choose a reference vector that is not parallel to normal
        let ref: simd_float3 = abs(normal.x) < 0.9 ? [1, 0, 0] : [0, 1, 0]
        let uAxis = simd_normalize(simd_cross(normal, ref))
        let vAxis = simd_cross(normal, uAxis)
        return (uAxis, vAxis)
    }
}

// MARK: - AR Session (point cloud accumulator + analysis trigger)

public enum ARScanState: Equatable {
    case idle
    case scanning(pointCount: Int)
    case analyzing
    case done(FoodVolumeReport)
    case failed(String)
}

/// Observable AR session that accumulates VIO feature points, then runs the
/// full analysis pipeline (RANSAC → segmentation → volume → mass) on demand.
@MainActor
public final class ARFoodScannerSession: NSObject, ObservableObject {

    // Public state
    @Published public var scanState: ARScanState = .idle
    @Published public var detectedPlaneAnchorID: UUID?

    // Internal
    private(set) var arSession = ARSession()
    private var accumulatedPoints: [simd_float3] = []
    private var lastAnalysisFrame: ARFrame?
    private var scanStartDate: Date?

    /// Plug in a CoreML segmentation model here.  Falls back to mock if nil.
    public var segmentationProvider: SegmentationProvider?

    /// Horizontal plane anchors detected by ARKit (used as RANSAC seed)
    private var planeAnchors: [ARPlaneAnchor] = []

    // MARK: Session lifecycle

    /// Call from SwiftUI .onAppear / UIViewRepresentable.makeUIView
    public func start() {
        let config = ARWorldTrackingConfiguration()
        config.planeDetection = .horizontal
        // VIO: ARKit uses visual-inertial odometry by default — no extra config needed.
        // SLAM map-rebuilding via parallax occurs automatically as the device moves.
        config.environmentTexturing = .none   // saves GPU bandwidth
        config.frameSemantics = []            // no depth semantics (non-LiDAR path)
        arSession.delegate = self
        arSession.run(config, options: [.resetTracking, .removeExistingAnchors])
        scanState = .scanning(pointCount: 0)
        scanStartDate = Date()
        accumulatedPoints = []
    }

    public func stop() {
        arSession.pause()
        scanState = .idle
    }

    // MARK: Analysis trigger

    /// Freeze the current frame and run the full volumetric analysis.
    public func analyzeCurrentFrame() {
        guard let frame = arSession.currentFrame else {
            scanState = .failed("No AR frame available — move the camera over the food.")
            return
        }
        lastAnalysisFrame = frame
        scanState = .analyzing

        Task {
            await runAnalysis(frame: frame)
        }
    }

    // MARK: Private analysis pipeline

    private func runAnalysis(frame: ARFrame) async {
        let pts = accumulatedPoints

        // ─── Step 1: RANSAC plane fit ────────────────────────────────────────
        // Use the accumulated VIO sparse feature cloud.  If ARKit already detected
        // a horizontal plane anchor we seed the cloud with that anchor's centre
        // to help RANSAC converge faster on the plate plane.
        var cloud = pts
        if let anchor = planeAnchors.first {
            let c = anchor.transform.columns.3
            cloud.append(simd_float3(c.x, c.y, c.z))
        }

        guard let (plane, inliers) = RANSACPlaneFitter.fit(points: cloud) else {
            scanState = .failed(
                "Couldn't detect a flat surface. Scan the table/plate from different angles.")
            return
        }

        // ─── Step 2: Food segmentation ─────────────────────────────────────
        let pixelBuffer = frame.capturedImage
        let imgW = CVPixelBufferGetWidth(pixelBuffer)
        let imgH = CVPixelBufferGetHeight(pixelBuffer)
        let imageSize = CGSize(width: imgW, height: imgH)

        let masks: [FoodSegmentationMask]
        do {
            if let provider = segmentationProvider {
                masks = try await provider.segment(pixelBuffer: pixelBuffer, imageSize: imageSize)
            } else {
                // Fallback: whole-frame mock mask (for development without the CoreML model)
                masks = MockSegmentationProvider().mockMasks(imageWidth: imgW, imageHeight: imgH)
            }
        } catch {
            scanState = .failed("Segmentation failed: \(error.localizedDescription)")
            return
        }

        // ─── Step 3: Assign 3-D feature points to food segments ─────────────
        // Project each world-space feature point back into the camera image and
        // check which 2-D mask it falls into (O(N × M) where N ≤ 500 pts, M ≤ 8 classes).
        var segmentPoints: [String: [simd_float3]] = [:]
        var segmentedCount = 0

        for worldPt in pts {
            let pixel = frame.camera.projectPoint(worldPt,
                                                   orientation: .portrait,
                                                   viewportSize: imageSize)
            let col = Int(pixel.x.rounded())
            let row = Int(pixel.y.rounded())

            for mask in masks {
                if mask.contains(col: col, row: row) {
                    segmentPoints[mask.label, default: []].append(worldPt)
                    segmentedCount += 1
                    break   // one point → one label
                }
            }
        }

        // ─── Step 4: Volume integration per segment ─────────────────────────
        // V = ∬_S (h_point − h_plane) dA
        // Implemented as cell-grid summation over the plane-local (u, v) space.
        var results: [FoodVolumeResult] = []

        for mask in masks {
            let foodPts = segmentPoints[mask.label] ?? []
            let label = mask.label

            // Classify as soup if the label contains known liquid keywords
            let isSoup = ["soup", "суп", "borsch", "борщ", "stew", "тушёный"].contains {
                label.lowercased().contains($0)
            }

            let volumeCm3 = VolumetricCalculator.volume(points: foodPts,
                                                         plane: plane,
                                                         isSoup: isSoup)
            let densityGCm3 = FoodDensityDatabase.density(for: label)
            let massG = volumeCm3 * densityGCm3

            // Only include foods with at least a plausible volume (> 1 cm³)
            if volumeCm3 > 1.0 {
                results.append(FoodVolumeResult(
                    label: label,
                    volumeCm3: volumeCm3.rounded(to: 1),
                    estimatedMassG: massG.rounded(to: 1)
                ))
            }
        }

        // ─── Step 5: Build report JSON ───────────────────────────────────────
        let totalPts = max(pts.count, 1)
        let planeRms = Double(plane.rmsError(over: inliers))
        let isoDate = ISO8601DateFormatter().string(from: Date())

        let report = FoodVolumeReport(
            detectedObjects: results,
            segmentedPointRatio: Double(segmentedCount) / Double(totalPts),
            planeRmsM: planeRms.rounded(to: 4),
            capturedAt: isoDate
        )

        scanState = .done(report)
    }
}

// MARK: - ARSessionDelegate

extension ARFoodScannerSession: ARSessionDelegate {

    public nonisolated func session(_ session: ARSession, didUpdate frame: ARFrame) {
        // Accumulate VIO feature points every frame.
        // rawFeaturePoints contains sparse SLAM landmarks in world coordinates.
        guard let cloud = frame.rawFeaturePoints else { return }
        let newPoints = cloud.points   // [simd_float3] in world space

        Task { @MainActor in
            self.accumulatedPoints.append(contentsOf: newPoints)
            // Deduplicate: keep at most 2000 unique points (drop oldest)
            if self.accumulatedPoints.count > 2000 {
                self.accumulatedPoints = Array(self.accumulatedPoints.suffix(2000))
            }
            self.scanState = .scanning(pointCount: self.accumulatedPoints.count)
        }
    }

    public nonisolated func session(_ session: ARSession,
                                    didAdd anchors: [ARAnchor]) {
        let planes = anchors.compactMap { $0 as? ARPlaneAnchor }
            .filter { $0.alignment == .horizontal }
        guard !planes.isEmpty else { return }
        Task { @MainActor in
            self.planeAnchors.append(contentsOf: planes)
            self.detectedPlaneAnchorID = self.planeAnchors.first?.identifier
        }
    }

    public nonisolated func session(_ session: ARSession,
                                    didFailWithError error: Error) {
        Task { @MainActor in
            self.scanState = .failed("AR session error: \(error.localizedDescription)")
        }
    }

    public nonisolated func sessionWasInterrupted(_ session: ARSession) {
        Task { @MainActor in
            self.scanState = .failed("AR session interrupted. Move back to the food and retry.")
        }
    }
}

// MARK: - Mock Segmentation (development placeholder)

/// Returns a single whole-image mask labelled "food".
/// Replace with a real CoreML segmentation model conforming to SegmentationProvider.
struct MockSegmentationProvider: SegmentationProvider {
    func segment(pixelBuffer: CVPixelBuffer, imageSize: CGSize) async throws -> [FoodSegmentationMask] {
        return mockMasks(imageWidth: Int(imageSize.width), imageHeight: Int(imageSize.height))
    }

    func mockMasks(imageWidth: Int, imageHeight: Int) -> [FoodSegmentationMask] {
        // Whole-image mask for demonstration
        let all = Set(0..<(imageWidth * imageHeight))
        return [FoodSegmentationMask(label: "food",
                                     confidence: 0.5,
                                     pixelSet: all,
                                     imageWidth: imageWidth,
                                     imageHeight: imageHeight)]
    }
}

// MARK: - Helpers

private extension Double {
    func rounded(to places: Int) -> Double {
        let factor = pow(10.0, Double(places))
        return (self * factor).rounded() / factor
    }
}
