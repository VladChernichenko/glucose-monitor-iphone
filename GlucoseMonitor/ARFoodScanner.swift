import ARKit
import Accelerate
import CoreML
import Vision
import UIKit
import simd

// MARK: - Nutrient Summary (full-meal result)

/// Complete result of one meal scan: all detected components with nutrition + the captured frame.
public struct NutrientSummary: Identifiable {
    public let id:            UUID   = UUID()
    public let components:    [FoodComponent]
    public let capturedImage: UIImage
    public let capturedAt:    Date

    public var totalCalories:  Double { components.compactMap(\.nutrients?.calories).reduce(0, +) }
    public var totalCarbsG:    Double { components.compactMap(\.nutrients?.carbsG).reduce(0, +) }
    public var totalProteinG:  Double { components.compactMap(\.nutrients?.proteinG).reduce(0, +) }
    public var totalFatG:      Double { components.compactMap(\.nutrients?.fatG).reduce(0, +) }
    public var totalGL:        Double { components.compactMap(\.nutrients?.glycemicLoad).reduce(0, +) }
    public var averageGI:      Double? {
        let gis = components.compactMap(\.nutrients?.glycemicIndex)
        return gis.isEmpty ? nil : gis.reduce(0, +) / Double(gis.count)
    }

    /// Human-readable ingredient list for note text.
    public var noteDescription: String {
        components.map { "\($0.label) \(Int($0.massG.rounded()))g" }.joined(separator: ", ")
    }
}

// MARK: - Scan State

public enum ScanState: Equatable {
    case idle
    case capturing
    case processingVision
    case verifyingWithQwen
    case fetchingNutrition(progress: Int, total: Int)
    case done(NutrientSummary)
    case failed(String)

    public static func == (lhs: ScanState, rhs: ScanState) -> Bool {
        switch (lhs, rhs) {
        case (.idle, .idle), (.capturing, .capturing),
             (.processingVision, .processingVision),
             (.verifyingWithQwen, .verifyingWithQwen):           return true
        case (.fetchingNutrition(let p1, let t1),
              .fetchingNutrition(let p2, let t2)):               return p1 == p2 && t1 == t2
        case (.done, .done), (.failed, .failed):                 return true
        default:                                                  return false
        }
    }
}

// MARK: - ARKitManager (LiDAR-backed AR session)
//
// Configures an ARWorldTrackingConfiguration with `.sceneDepth` frame semantics,
// giving per-pixel Float32 depth values in metres from the LiDAR scanner.
// On devices without LiDAR the session runs without depth semantics and
// VolumeCalculator falls back to a bounding-box heuristic.

@MainActor
public final class ARSessionManager: NSObject, ObservableObject {

    @Published public var scanState:        ScanState = .idle
    @Published public var isLiDARAvailable: Bool      = false

    public private(set) var arSession = ARSession()

    public override init() {
        super.init()
        isLiDARAvailable = ARWorldTrackingConfiguration.supportsFrameSemantics(.sceneDepth)
    }

    public func start() {
        let config = ARWorldTrackingConfiguration()
        config.planeDetection = .horizontal
        if ARWorldTrackingConfiguration.supportsFrameSemantics(.sceneDepth) {
            config.frameSemantics = [.sceneDepth]
        }
        arSession.delegate = self
        arSession.run(config, options: [.resetTracking, .removeExistingAnchors])
        scanState = .capturing
    }

    public func stop() {
        arSession.pause()
        scanState = .idle
    }

    public func captureCurrentFrame() -> ARFrame? {
        arSession.currentFrame
    }
}

extension ARSessionManager: ARSessionDelegate {
    public nonisolated func session(_ session: ARSession, didFailWithError error: Error) {
        Task { @MainActor in self.scanState = .failed("AR error: \(error.localizedDescription)") }
    }
    public nonisolated func sessionWasInterrupted(_ session: ARSession) {
        Task { @MainActor in self.scanState = .failed("AR session interrupted.") }
    }
}

// Spec alias
public typealias ARKitManager = ARSessionManager

// MARK: - VisionProcessor (CoreML + YOLOv11-seg)
//
// Runs FoodSegModel inference via VNCoreMLRequest and decodes the YOLOv11-seg
// dual-tensor output into per-instance binary segmentation masks.
//
// Tensor layout:
//   "output0" -> [1, N, 4 + C + K]
//       N = 8400 candidate boxes (YOLO grid)
//       4 = (cx, cy, w, h)  normalised box
//       C = 154             class scores (FoodSeg154)
//       K = 32              mask prototype coefficients
//
//   "output1" -> [1, K, H, W]
//       K = 32, H = W = 160  prototype mask bank
//
// Per-detection mask assembly (Accelerate-accelerated):
//   raw[i] = Σ_k coeff[k] × proto[k, i]      (dot product over K protos, per pixel i)
//   mask[i] = sigmoid(raw[i]) > 0.5
//
//   Using cblas_sgemv this collapses the K-dimension across all H×W pixels in a
//   single BLAS call (~10-100× faster than nested Swift loops).

public final class FoodRecognitionService {

    private let model: VNCoreMLModel

    public init() throws {
        // Try fine-tuned model first, fall back to base model
        let name = Bundle.main.url(forResource: "best", withExtension: "mlmodelc") != nil
                   ? "best" : "yolo11n-seg"
        guard let url = Bundle.main.url(forResource: name, withExtension: "mlmodelc") else {
            throw FoodScanError.modelNotFound
        }
        model = try VNCoreMLModel(for: MLModel(contentsOf: url))
    }

    public func recognize(pixelBuffer: CVPixelBuffer,
                          imageSize: CGSize) async throws -> [SegmentationResult] {
        try await withCheckedThrowingContinuation { continuation in
            let request = VNCoreMLRequest(model: model) { req, error in
                if let error = error {
                    continuation.resume(throwing: FoodScanError.visionFailed(error.localizedDescription))
                    return
                }
                let obs = req.results as? [VNCoreMLFeatureValueObservation] ?? []
                continuation.resume(returning: Self.decode(observations: obs, imageSize: imageSize))
            }
            request.imageCropAndScaleOption = .scaleFill
            do {
                try VNImageRequestHandler(cvPixelBuffer: pixelBuffer,
                                          orientation: .up, options: [:]).perform([request])
            } catch {
                continuation.resume(throwing: FoodScanError.visionFailed(error.localizedDescription))
            }
        }
    }

    // MARK: YOLOv11-seg decoder
    //
    // CoreML export renames tensors; actual output names are var_1325 / var_1363.
    // Tensor layout from export: det = [1, F, N]  where F=190=(4+154+32), N=8400
    // (PyTorch-style channel-first - transposed vs the original [1, N, F] assumption)

    private static func decode(observations: [VNCoreMLFeatureValueObservation],
                               imageSize: CGSize) -> [SegmentationResult] {
        // Accept both original names and CoreML-renamed variants
        let detObs   = observations.first(where: { ["output0","var_1325"].contains($0.featureName) })
        let protoObs = observations.first(where: { ["output1","var_1363"].contains($0.featureName) })

        guard
            let detObs, let protoObs,
            let det   = detObs.featureValue.multiArrayValue,
            let proto = protoObs.featureValue.multiArrayValue
        else { return [] }

        // Determine tensor layout: [1, N, F] vs [1, F, N]
        // F = 4 + 154 + 32 = 190;  N = 8400
        let C = 154
        let K = 32
        let F = 4 + C + K  // 190

        let dim1 = det.shape[1].intValue
        let dim2 = det.shape[2].intValue
        // If dim1==F the tensor is channel-first [1, F, N]
        let channelFirst = (dim1 == F)
        let N = channelFirst ? dim2 : dim1

        let pH = proto.shape[2].intValue   // 160
        let pW = proto.shape[3].intValue   // 160
        let pPixels = pH * pW
        let confThreshold: Float = 0.25    // lowered from 0.45 for fine-tuned model

        // YOLO11 outputs box coords in model-input pixel space [0, imgsz].
        // Divide by imgsz to get normalised [0, 1] coordinates.
        let imgsz: Float = 640.0

        // Helper: access det[0, feature, candidate] or det[0, candidate, feature]
        func detVal(candidate i: Int, feature j: Int) -> Float {
            if channelFirst {
                return Float(truncating: det[[0, j, i] as [NSNumber]])
            } else {
                return Float(truncating: det[[0, i, j] as [NSNumber]])
            }
        }

        // -- Copy proto tensor to a contiguous Float32 buffer [K × pPixels] ------
        let protoFlat: [Float] = (0..<K * pPixels).map { idx in
            let k = idx / pPixels
            let i = idx % pPixels
            return Float(truncating: proto[[0, k, i / pW, i % pW] as [NSNumber]])
        }

        var results: [SegmentationResult] = []

        for i in 0..<N {
            // Find highest-scoring class first (fast reject before box decode).
            var bestClass = 0
            var bestScore: Float = 0
            for c in 0..<C {
                let s = detVal(candidate: i, feature: 4 + c)
                if s > bestScore { bestScore = s; bestClass = c }
            }
            guard bestScore >= confThreshold else { continue }

            // Decode bounding box - divide by imgsz to normalise to [0, 1].
            let cx = detVal(candidate: i, feature: 0) / imgsz
            let cy = detVal(candidate: i, feature: 1) / imgsz
            let bw = detVal(candidate: i, feature: 2) / imgsz
            let bh = detVal(candidate: i, feature: 3) / imgsz

            // Read K mask coefficients.
            var coeffs = [Float](repeating: 0, count: K)
            for k in 0..<K {
                coeffs[k] = detVal(candidate: i, feature: 4 + C + k)
            }

            // -- Accelerate: raw[j] = Σ_k coeffs[k] × protoFlat[k * pPixels + j] --
            var raw = [Float](repeating: 0, count: pPixels)
            cblas_sgemv(CblasRowMajor, CblasTrans,
                        Int32(K), Int32(pPixels),
                        1.0, protoFlat, Int32(pPixels),
                        coeffs, 1,
                        0.0, &raw, 1)

            // sigmoid(x) > 0.5  ⟺  x > 0
            let mask: [Bool] = raw.map { $0 > 0 }

            results.append(SegmentationResult(
                label:       FoodSeg154Labels.name(at: bestClass),
                confidence:  bestScore,
                boundingBox: CGRect(x: CGFloat(cx - bw / 2), y: CGFloat(cy - bh / 2),
                                    width: CGFloat(bw), height: CGFloat(bh)),
                pixelMask:   mask,
                maskWidth:   pW,
                maskHeight:  pH,
                imageSize:   imageSize
            ))
        }
        // Apply IoU-based NMS before returning.
        // Threshold 0.30 (was 0.45): cross-class overlaps at 30 %+ are treated as
        // duplicate detections of the same physical object and suppressed.
        return nms(results, iouThreshold: 0.30)
    }

    /// Non-Maximum Suppression - removes overlapping detections of the same class.
    private static func nms(_ results: [SegmentationResult],
                             iouThreshold: Float) -> [SegmentationResult] {
        let sorted = results.sorted { $0.confidence > $1.confidence }
        var kept: [SegmentationResult] = []
        var suppressed = Set<Int>()
        for (i, a) in sorted.enumerated() {
            guard !suppressed.contains(i) else { continue }
            kept.append(a)
            for (j, b) in sorted.enumerated() where j > i {
                if iou(a.boundingBox, b.boundingBox) > CGFloat(iouThreshold) {
                    suppressed.insert(j)
                }
            }
        }
        return Array(kept.prefix(8))
    }

    private static func iou(_ a: CGRect, _ b: CGRect) -> CGFloat {
        let inter = a.intersection(b)
        guard !inter.isNull else { return 0 }
        let interArea = inter.width * inter.height
        let unionArea = a.width * a.height + b.width * b.height - interArea
        return unionArea > 0 ? interArea / unionArea : 0
    }
}

// Spec alias
public typealias VisionProcessor = FoodRecognitionService

// MARK: - VolumeCalculator (LiDAR depth integration)
//
// Volume algorithm per food segment:
//
//   1. Reference depth  z_ref  = median depth sampled in a ring *outside* the bounding
//      box. This represents the plate / table surface (our baseline plane).
//
//   2. For each image pixel (u, v) inside the food mask:
//        a. z_food = LiDAR depth at (u, v), in metres (Float32).
//        b. Height above plate:  h = z_ref − z_food
//           (food is closer to camera -> smaller z -> positive h).
//        c. Physical footprint of one pixel at depth z_food (thin-lens geometry):
//              Δx = z_food / fx   [m / px]
//              Δy = z_food / fy   [m / px]
//           where fx, fy are the focal lengths from ARCamera.intrinsics.
//        d. Voxel contribution:  dV = h × Δx × Δy   [m³]
//
//   3. V_total = Σ dV   [m³]  converted to cm³ by × 10⁶.

public struct VolumeCalculator {

    private static let m3ToCm3: Double = 1_000_000.0

    public static func volume(for segment: SegmentationResult,
                               depthMap: CVPixelBuffer,
                               intrinsics: simd_float3x3,
                               imageSize: CGSize) -> Double {
        let fx = Double(intrinsics.columns.0.x)   // focal length x (pixels)
        let fy = Double(intrinsics.columns.1.y)   // focal length y (pixels)

        let dW = CVPixelBufferGetWidth(depthMap)
        let dH = CVPixelBufferGetHeight(depthMap)
        let iW = Int(imageSize.width)
        let iH = Int(imageSize.height)
        // Scale factors - depth map resolution may differ from RGB frame resolution.
        let sx = Double(dW) / Double(iW)
        let sy = Double(dH) / Double(iH)

        CVPixelBufferLockBaseAddress(depthMap, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(depthMap, .readOnly) }
        guard let base = CVPixelBufferGetBaseAddress(depthMap) else { return 0 }
        let stride = CVPixelBufferGetBytesPerRow(depthMap) / MemoryLayout<Float32>.size
        let ptr    = base.bindMemory(to: Float32.self, capacity: dH * stride)

        let bbox = segment.boundingBox
        let zRef = referenceDepth(ptr: ptr, stride: stride, dW: dW, dH: dH, bbox: bbox)
        guard zRef > 0.05 else { return 0 }

        let x0 = max(0, Int(bbox.minX * imageSize.width))
        let x1 = min(iW, Int(bbox.maxX * imageSize.width))
        let y0 = max(0, Int(bbox.minY * imageSize.height))
        let y1 = min(iH, Int(bbox.maxY * imageSize.height))

        var totalM3: Double = 0
        for iy in y0..<y1 {
            for ix in x0..<x1 {
                let (mx, my) = segment.imageToMask(imageX: ix, imageY: iy)
                guard segment.contains(maskX: mx, maskY: my) else { continue }

                let dx = min(Int(Double(ix) * sx), dW - 1)
                let dy = min(Int(Double(iy) * sy), dH - 1)
                let z  = Double(ptr[dy * stride + dx])
                guard z.isFinite, z > 0.01 else { continue }

                let h = zRef - z
                guard h > 0.002 else { continue }   // discard sub-2 mm noise

                // Voxel volume: height × physical footprint of pixel at depth z.
                totalM3 += h * (z / fx) * (z / fy)
            }
        }
        let cm3 = totalM3 * m3ToCm3
        // Sanity cap: no single food item on a plate exceeds 3 litres (3000 cm³).
        // Values above this indicate bad LiDAR data or intrinsics - clamp rather
        // than return garbage that inflates calorie estimates by 6 orders of magnitude.
        return min(cm3, 3000.0)
    }

    /// Median depth of a ring of samples surrounding the food bounding box.
    /// Represents the plate / table surface (background plane).
    private static func referenceDepth(ptr: UnsafePointer<Float32>, stride: Int,
                                        dW: Int, dH: Int, bbox: CGRect) -> Double {
        let pad: Double = 0.18
        let ox0 = max(0,      Int((bbox.minX - bbox.width  * pad) * Double(dW)))
        let ox1 = min(dW - 1, Int((bbox.maxX + bbox.width  * pad) * Double(dW)))
        let oy0 = max(0,      Int((bbox.minY - bbox.height * pad) * Double(dH)))
        let oy1 = min(dH - 1, Int((bbox.maxY + bbox.height * pad) * Double(dH)))
        let ix0 = max(0,      Int(bbox.minX * Double(dW)))
        let ix1 = min(dW - 1, Int(bbox.maxX * Double(dW)))
        let iy0 = max(0,      Int(bbox.minY * Double(dH)))
        let iy1 = min(dH - 1, Int(bbox.maxY * Double(dH)))
        let step = max(1, Int(Double(dW) * 0.025))  // ~2.5 % spacing for speed

        var samples: [Double] = []
        var y = oy0
        while y <= oy1 { defer { y += step }
            var x = ox0
            while x <= ox1 { defer { x += step }
                if x >= ix0 && x <= ix1 && y >= iy0 && y <= iy1 { continue }
                let z = Double(ptr[y * stride + x])
                if z.isFinite && z > 0.08 && z < 3.0 { samples.append(z) }
            }
        }
        guard !samples.isEmpty else { return 0 }
        let sorted = samples.sorted()
        return sorted[sorted.count / 2]
    }
}

// MARK: - Density Mapper
//
// Maps food category labels to cooked bulk densities (g/cm³).
// Sources: USDA FoodData Central; Barbosa-Canovas (2005).

public struct DensityMapper {

    private static let table: [String: Double] = [
        // Proteins
        "chicken": 1.04, "beef": 1.05, "pork": 1.02, "fish": 1.00,
        "salmon": 1.00,  "tuna": 1.00, "shrimp": 0.98, "egg": 1.03,
        "tofu": 1.00,    "sausage": 1.03,
        // Grains & starches
        "white rice": 0.85, "brown rice": 0.83, "noodles": 0.80,
        "pasta": 0.80,      "bread": 0.32,      "oatmeal": 0.55,
        "potato": 0.90,     "sweet potato": 0.85,
        // Vegetables
        "broccoli": 0.37, "carrot": 0.60, "cabbage": 0.50,
        "beans": 0.95,    "lentils": 0.95, "peas": 0.85,
        "corn": 0.72,     "tomato": 0.95, "mushroom": 0.45,
        // Dairy
        "cheese": 1.10, "yogurt": 1.05, "milk": 1.03,
        // Dishes & prepared foods
        "soup": 1.02,  "stew": 1.05,  "porridge": 0.55,
        "pizza": 0.65, "burger": 0.75, "fried chicken": 0.85,
        "sushi": 0.90, "dumpling": 0.85, "pancake": 0.55,
        // Fruits
        "apple": 0.56, "banana": 0.94, "orange": 0.60, "avocado": 0.80,
        // Other
        "butter": 0.91, "salad": 0.40,
    ]
    public static let defaultDensity: Double = 0.85

    public static func density(for label: String) -> Double {
        let lower = label.lowercased()
        if let d = table[lower] { return d }
        for (k, d) in table where lower.contains(k) || k.contains(lower) { return d }
        return defaultDensity
    }
}

// MARK: - FoodSeg154 Class Names
// Order matches foodseg154.yaml generated by scripts/01_download_foodseg154.py

enum FoodSeg154Labels {
    private static let names: [String] = [
        // 0-9
        "candy","egg tart","french fries","chocolate","biscuit","popcorn",
        "pudding","ice cream","cheese butter","cake",
        // 10-19
        "wine","milkshake","coffee","juice","milk","tea","almond",
        "red beans","cashew","dried cranberries",
        // 20-29
        "soy","walnut","peanut","egg","apple","date","apricot",
        "avocado","banana","strawberry",
        // 30-39
        "cherry","blueberry","raspberry","mango","olives","peach",
        "lemon","pear","fig","pineapple",
        // 40-49
        "grape","kiwi","melon","orange","watermelon","steak","pork",
        "chicken duck","sausage","fried meat",
        // 50-59
        "lamb","sauce","crab","fish","shellfish","shrimp","soup",
        "bread","corn","hamburg",
        // 60-69
        "pizza","hanamaki baozi","wonton dumplings","tow","salad",
        "noodles pasta","rice","toast","croissant","roll",
        // 70-79
        "sandwich","eggplant","tomato","asparagus","broccoli",
        "celery stick","cilantro mint","snow peas","cabbage","hot pepper",
        // 80-89
        "parsley","mushroom","spring onion","birth pea","green vegetables",
        "okra","bamboo shoots","wild violet","chestnut","biscuits",
        // 90-99
        "egg tart","pie","tarts","pineapple cake","potato","mashed potato",
        "potato chips","spring roll","french fries","onion",
        // 100-109
        "garlic","ginger","sweet potato","purple sweet potato","yam","taro",
        "carrot","lotus root","white radish","beet",
        // 110-119
        "chinese turnip","pumpkin","winter melon","cucumber","gourd",
        "luffa","zucchini","leek","garlic","coriander",
        // 120-129
        "dill","basil","thyme","rosemary","marjoram","bay leaf","sage",
        "oregano","fennel","tarragon",
        // 130-139
        "chives","parsley","mint","lemon grass","wood ear mushroom",
        "king oyster mushroom","shiitake","enoki mushroom","straw mushroom",
        "oyster mushroom",
        // 140-153
        "button mushroom","truffle","bean sprout","mung bean","lentil",
        "kidney bean","chickpea","fava bean","tofu","natto",
        "tempeh","seitan","meat analogue","food",
    ]
    static func name(at index: Int) -> String {
        index < names.count ? names[index] : "food"
    }
}
