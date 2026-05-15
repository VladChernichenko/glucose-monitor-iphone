import Vision
import CoreML

// MARK: - YOLOv11 CoreML Segmentation Provider

/// Concrete SegmentationProvider that runs a YOLOv11-seg CoreML model via the
/// Vision framework.  Supports the two standard Ultralytics export formats:
///
///   • NMS=True  (recommended): model embeds NMS, outputs boxes + instance masks
///   • NMS=False (raw):         outputs raw prediction tensor + prototype masks;
///                              NMS is performed here before mask generation.
///
/// Export command (Python):
///   from ultralytics import YOLO
///   YOLO("yolo11n-seg.pt").export(format="coreml", nms=True, imgsz=640)
///
/// Then drag the resulting .mlpackage into Xcode and add it to the app target.
/// The model is loaded lazily on first `start()` call via `ARFoodScannerSession`.
public final class YOLOv11SegmentationProvider: SegmentationProvider {

    // MARK: - Configuration

    public struct Configuration {
        /// Filename of the CoreML model in the app bundle, without extension.
        /// Supports both .mlpackage and pre-compiled .mlmodelc.
        public var modelName: String = "yolo11n-seg"
        /// Minimum per-class confidence to accept a detection (0–1).
        public var confidenceThreshold: Float = 0.25
        /// IoU overlap threshold for non-max suppression (0–1).
        public var iouThreshold: Float = 0.45
        /// Input spatial size used during export (pixels, square).
        public var inputSize: Int = 640
        /// Override class-index → food label mapping.
        /// When nil: COCO-80 food classes are used for 80-class models;
        /// other class counts receive "food_N" labels.
        public var customLabels: [Int: String]?
        public init() {}
    }

    // MARK: - Properties

    private let visionModel: VNCoreMLModel
    private let config: Configuration

    // COCO-80 food class indices (0-indexed) and their display names.
    // Only these classes are kept when analysing a COCO-trained model.
    private static let cocoFoodClasses: [Int: String] = [
        46: "banana", 47: "apple", 48: "sandwich", 49: "orange",
        50: "broccoli", 51: "carrot", 52: "hot dog", 53: "pizza",
        54: "donut", 55: "cake"
    ]
    // Also keep plate/bowl so we can use them as region cues
    private static let cocoDishClasses: [Int: String] = [
        45: "bowl"
    ]
    private static let cocoFoodSet: Set<Int> = Set(cocoFoodClasses.keys)
        .union(cocoDishClasses.keys)

    // MARK: - Init

    /// Loads the CoreML model from the main bundle.
    /// Throws `YOLOv11Error.modelNotFound` when the .mlpackage / .mlmodelc is absent.
    public init(configuration: Configuration = .init()) throws {
        let name = configuration.modelName
        guard let url = Bundle.main.url(forResource: name, withExtension: "mlpackage")
                     ?? Bundle.main.url(forResource: name, withExtension: "mlmodelc") else {
            throw YOLOv11Error.modelNotFound(name)
        }
        let mlConfig = MLModelConfiguration()
        mlConfig.computeUnits = .all        // prefer Neural Engine → lowest latency
        let mlModel = try MLModel(contentsOf: url, configuration: mlConfig)
        visionModel = try VNCoreMLModel(for: mlModel)
        config = configuration
    }

    // MARK: - SegmentationProvider

    public func segment(pixelBuffer: CVPixelBuffer,
                        imageSize: CGSize) async throws -> [FoodSegmentationMask] {
        try await withCheckedThrowingContinuation { continuation in
            let request = VNCoreMLRequest(model: visionModel) { [weak self] req, err in
                guard let self else { return }
                if let err { continuation.resume(throwing: err); return }
                do {
                    let masks = try self.parse(results: req.results, imageSize: imageSize)
                    continuation.resume(returning: masks)
                } catch {
                    continuation.resume(throwing: error)
                }
            }
            // scaleFill matches the export imgsz without letterboxing distortion
            request.imageCropAndScaleOption = .scaleFill

            do {
                // ARKit frames are in landscape-right orientation; .right corrects to portrait
                let handler = VNImageRequestHandler(cvPixelBuffer: pixelBuffer,
                                                    orientation: .right,
                                                    options: [:])
                try handler.perform([request])
            } catch {
                continuation.resume(throwing: error)
            }
        }
    }

    // MARK: - Top-level result dispatcher

    private func parse(results: [VNObservation]?,
                       imageSize: CGSize) throws -> [FoodSegmentationMask] {
        guard let results, !results.isEmpty else { return [] }

        // Path A: model has built-in classifier metadata → high-level objects
        if let highLevel = results as? [VNRecognizedObjectObservation] {
            return parseHighLevel(highLevel, imageSize: imageSize)
        }
        // Path B: raw tensor observations
        if let raw = results as? [VNCoreMLFeatureValueObservation] {
            return try parseRawTensors(raw, imageSize: imageSize)
        }
        return []
    }

    // MARK: - Path A: High-level object observations
    // Produced when the CoreML model includes classifier metadata.
    // Vision gives us normalised bounding boxes; we build rectangular pixel masks.

    private func parseHighLevel(_ obs: [VNRecognizedObjectObservation],
                                 imageSize: CGSize) -> [FoodSegmentationMask] {
        let W = Int(imageSize.width), H = Int(imageSize.height)
        var masks: [FoodSegmentationMask] = []
        for det in obs {
            guard let top = det.labels.first,
                  top.confidence >= config.confidenceThreshold else { continue }
            // Vision bottom-left origin → flip Y for top-left image origin
            let box = det.boundingBox
            let x0 = max(0, Int((box.minX       * CGFloat(W)).rounded()))
            let y0 = max(0, Int(((1 - box.maxY) * CGFloat(H)).rounded()))
            let x1 = min(W, Int((box.maxX       * CGFloat(W)).rounded()))
            let y1 = min(H, Int(((1 - box.minY) * CGFloat(H)).rounded()))
            let pixels = rectPixels(x0: x0, y0: y0, x1: x1, y1: y1, W: W)
            guard !pixels.isEmpty else { continue }
            masks.append(FoodSegmentationMask(label: top.identifier,
                                               confidence: top.confidence,
                                               pixelSet: pixels,
                                               imageWidth: W, imageHeight: H))
        }
        return masks
    }

    // MARK: - Path B: Raw tensor parsing

    private func parseRawTensors(_ obs: [VNCoreMLFeatureValueObservation],
                                  imageSize: CGSize) throws -> [FoodSegmentationMask] {
        // Classify tensors by shape:
        //   [1, C, NA]        C > 36 → raw prediction tensor (4 bbox + classes + 32 coefs)
        //   [1, 32, pH, pW]          → prototype masks
        //   [1, N, 4]                → NMS bounding boxes (normalised XYXY)
        //   [1, N, 1] (first seen)   → NMS confidence scores
        //   [1, N, 1] (second seen)  → NMS class indices
        //   [1, N, pH, pW]           → NMS instance masks

        var predArray:  MLMultiArray?   // raw [1, C, NA]
        var protoArray: MLMultiArray?   // [1, 32, pH, pW]
        var nmsBoxes:   MLMultiArray?   // [1, N, 4]
        var nmsScores:  MLMultiArray?   // [1, N, 1]
        var nmsClasses: MLMultiArray?   // [1, N, 1]
        var nmsMasks:   MLMultiArray?   // [1, N, pH, pW]

        for o in obs {
            guard let arr = o.featureValue.multiArrayValue else { continue }
            let sh = arr.shape.map { $0.intValue }
            switch sh.count {
            case 3 where sh[0] == 1 && sh[1] > 36:
                predArray = arr
            case 3 where sh[0] == 1 && sh[2] == 4:
                nmsBoxes = arr
            case 3 where sh[0] == 1 && sh[2] == 1:
                // First [1,N,1] is scores, second is class indices
                if nmsScores == nil { nmsScores = arr } else { nmsClasses = arr }
            case 4 where sh[0] == 1 && sh[1] == 32:
                protoArray = arr
            case 4 where sh[0] == 1 && sh[1] > 1:
                nmsMasks = arr
            default:
                break
            }
        }

        if let boxes = nmsBoxes, let scores = nmsScores {
            // NMS already done inside the model
            return parseNMSOutput(boxes: boxes, scores: scores,
                                  classes: nmsClasses, masks: nmsMasks,
                                  imageSize: imageSize)
        }
        if let pred = predArray, let proto = protoArray {
            // Raw output — decode + NMS here
            return decodeRawPredictions(pred: pred, proto: proto, imageSize: imageSize)
        }
        throw YOLOv11Error.unexpectedOutputShape
    }

    // MARK: NMS output path (model exported with nms=True)

    private func parseNMSOutput(boxes: MLMultiArray, scores: MLMultiArray,
                                 classes: MLMultiArray?, masks: MLMultiArray?,
                                 imageSize: CGSize) -> [FoodSegmentationMask] {
        let N    = boxes.shape[1].intValue
        let W    = Int(imageSize.width)
        let H    = Int(imageSize.height)

        let boxPtr   = boxes.dataPointer.assumingMemoryBound(to: Float32.self)
        let scorePtr = scores.dataPointer.assumingMemoryBound(to: Float32.self)
        let classPtr = classes.map { $0.dataPointer.assumingMemoryBound(to: Float32.self) }

        var protoH = 0, protoW = 0
        var maskPtr: UnsafePointer<Float32>?
        if let m = masks {
            protoH  = m.shape[2].intValue
            protoW  = m.shape[3].intValue
            maskPtr = UnsafePointer(m.dataPointer.assumingMemoryBound(to: Float32.self))
        }

        var result: [FoodSegmentationMask] = []
        for n in 0..<N {
            let score = scorePtr[n]
            guard score >= config.confidenceThreshold else { continue }

            let classIdx = classPtr.map { Int($0[n].rounded()) } ?? 0
            let label = labelForClass(classIdx, numClasses: 0)

            // Normalised XYXY (relative to inputSize or [0,1] depending on export)
            let x0f = boxPtr[n * 4 + 0]
            let y0f = boxPtr[n * 4 + 1]
            let x1f = boxPtr[n * 4 + 2]
            let y1f = boxPtr[n * 4 + 3]

            // Values > 1 → likely in pixel space of inputSize; normalise
            let scale: Float = max(x1f, y1f) > 1.1 ? Float(config.inputSize) : 1.0
            let box = CGRect(x: CGFloat(x0f / scale), y: CGFloat(y0f / scale),
                             width: CGFloat((x1f - x0f) / scale),
                             height: CGFloat((y1f - y0f) / scale))

            var pixels: Set<Int>
            if let mPtr = maskPtr, protoH > 0 {
                pixels = thresholdMask(ptr: mPtr, offset: n * protoH * protoW,
                                       protoH: protoH, protoW: protoW,
                                       box: box, imageW: W, imageH: H)
            } else {
                let ix0 = max(0, Int((box.minX * CGFloat(W)).rounded()))
                let iy0 = max(0, Int((box.minY * CGFloat(H)).rounded()))
                let ix1 = min(W, Int((box.maxX * CGFloat(W)).rounded()))
                let iy1 = min(H, Int((box.maxY * CGFloat(H)).rounded()))
                pixels = rectPixels(x0: ix0, y0: iy0, x1: ix1, y1: iy1, W: W)
            }

            guard !pixels.isEmpty else { continue }
            result.append(FoodSegmentationMask(label: label, confidence: score,
                                                pixelSet: pixels,
                                                imageWidth: W, imageHeight: H))
        }
        return result
    }

    // MARK: Raw prediction decode path (nms=False export)

    private struct Detection {
        let label: String
        let confidence: Float
        let box: CGRect             // normalised [0,1] XYXY
        let maskCoefs: [Float]      // 32 prototype coefficients
    }

    private func decodeRawPredictions(pred: MLMultiArray,
                                       proto: MLMultiArray,
                                       imageSize: CGSize) -> [FoodSegmentationMask] {
        let sh         = pred.shape.map { $0.intValue }
        let channels   = sh[1]
        let numAnchors = sh[2]
        let numClasses = channels - 4 - 32
        guard numClasses > 0 else { return [] }

        let protoSh = proto.shape.map { $0.intValue }
        let protoH  = protoSh[2]
        let protoW  = protoSh[3]

        // Flat pointer access — avoids NSNumber boxing per element (~10× faster)
        let predPtr  = pred.dataPointer.assumingMemoryBound(to: Float32.self)
        let protoPtr = proto.dataPointer.assumingMemoryBound(to: Float32.self)

        var dets: [Detection] = []

        for a in 0..<numAnchors {
            // Find highest-confidence class for this anchor
            var maxConf: Float = 0
            var maxCls  = 0
            for c in 0..<numClasses {
                let v = predPtr[(4 + c) * numAnchors + a]
                if v > maxConf { maxConf = v; maxCls = c }
            }
            guard maxConf >= config.confidenceThreshold else { continue }

            // For COCO-80 models, skip non-food classes early
            if numClasses == 80 && !Self.cocoFoodSet.contains(maxCls) { continue }

            let label = labelForClass(maxCls, numClasses: numClasses)

            // CxCyWH (normalised to inputSize) → XYXY [0,1]
            let s  = Float(config.inputSize)
            let cx = predPtr[0 * numAnchors + a] / s
            let cy = predPtr[1 * numAnchors + a] / s
            let bw = predPtr[2 * numAnchors + a] / s
            let bh = predPtr[3 * numAnchors + a] / s
            let box = CGRect(x: CGFloat(cx - bw / 2), y: CGFloat(cy - bh / 2),
                             width: CGFloat(bw), height: CGFloat(bh))

            // 32 mask prototype coefficients
            var coefs = [Float](repeating: 0, count: 32)
            let coefBase = (4 + numClasses) * numAnchors
            for m in 0..<32 { coefs[m] = predPtr[coefBase + m * numAnchors + a] }

            dets.append(Detection(label: label, confidence: maxConf, box: box, maskCoefs: coefs))
        }

        let kept = nonMaxSuppression(dets)
        let W = Int(imageSize.width), H = Int(imageSize.height)

        return kept.compactMap { det in
            let pixels = sigmoidMask(coefs: det.maskCoefs,
                                     protoPtr: protoPtr,
                                     protoH: protoH, protoW: protoW,
                                     box: det.box, imageW: W, imageH: H)
            guard !pixels.isEmpty else { return nil }
            return FoodSegmentationMask(label: det.label, confidence: det.confidence,
                                        pixelSet: pixels, imageWidth: W, imageHeight: H)
        }
    }

    // MARK: Mask generation

    /// mask[h,w] = sigmoid(Σ coef[k] * proto[k,h,w])
    /// Optimisation: sigmoid(x) > 0.5  ⟺  x > 0  → skip exp(), just check sign.
    private func sigmoidMask(coefs: [Float],
                              protoPtr: UnsafePointer<Float32>,
                              protoH: Int, protoW: Int,
                              box: CGRect, imageW: Int, imageH: Int) -> Set<Int> {
        let protoArea = protoH * protoW
        let x0 = max(0, Int((box.minX * CGFloat(imageW)).rounded()))
        let y0 = max(0, Int((box.minY * CGFloat(imageH)).rounded()))
        let x1 = min(imageW, Int((box.maxX * CGFloat(imageW)).rounded()))
        let y1 = min(imageH, Int((box.maxY * CGFloat(imageH)).rounded()))

        var pixels = Set<Int>()
        for row in y0..<y1 {
            let ph = min(protoH - 1, Int(Float(row) / Float(imageH) * Float(protoH)))
            for col in x0..<x1 {
                let pw = min(protoW - 1, Int(Float(col) / Float(imageW) * Float(protoW)))
                var val: Float = 0
                for k in 0..<32 {
                    val += coefs[k] * protoPtr[k * protoArea + ph * protoW + pw]
                }
                if val > 0 { pixels.insert(row * imageW + col) }
            }
        }
        return pixels
    }

    /// Threshold a pre-computed float mask (NMS export path).
    private func thresholdMask(ptr: UnsafePointer<Float32>, offset: Int,
                                protoH: Int, protoW: Int,
                                box: CGRect, imageW: Int, imageH: Int) -> Set<Int> {
        let x0 = max(0, Int((box.minX * CGFloat(imageW)).rounded()))
        let y0 = max(0, Int((box.minY * CGFloat(imageH)).rounded()))
        let x1 = min(imageW, Int((box.maxX * CGFloat(imageW)).rounded()))
        let y1 = min(imageH, Int((box.maxY * CGFloat(imageH)).rounded()))

        var pixels = Set<Int>()
        for row in y0..<y1 {
            let ph = min(protoH - 1, Int(Float(row) / Float(imageH) * Float(protoH)))
            for col in x0..<x1 {
                let pw = min(protoW - 1, Int(Float(col) / Float(imageW) * Float(protoW)))
                if ptr[offset + ph * protoW + pw] > 0.5 { pixels.insert(row * imageW + col) }
            }
        }
        return pixels
    }

    // MARK: Non-max suppression (greedy, confidence-descending)

    private func nonMaxSuppression(_ dets: [Detection]) -> [Detection] {
        let sorted = dets.sorted { $0.confidence > $1.confidence }
        var suppressed = [Bool](repeating: false, count: sorted.count)
        var kept: [Detection] = []
        for i in 0..<sorted.count {
            guard !suppressed[i] else { continue }
            kept.append(sorted[i])
            for j in (i + 1)..<sorted.count {
                guard !suppressed[j] else { continue }
                if iou(sorted[i].box, sorted[j].box) > config.iouThreshold {
                    suppressed[j] = true
                }
            }
        }
        return kept
    }

    // MARK: Helpers

    private func iou(_ a: CGRect, _ b: CGRect) -> Float {
        let inter = a.intersection(b)
        guard !inter.isNull else { return 0 }
        let i = inter.width * inter.height
        let u = a.width * a.height + b.width * b.height - i
        return Float(i / max(u, 1e-7))
    }

    private func rectPixels(x0: Int, y0: Int, x1: Int, y1: Int, W: Int) -> Set<Int> {
        var s = Set<Int>()
        for r in y0..<y1 { for c in x0..<x1 { s.insert(r * W + c) } }
        return s
    }

    private func labelForClass(_ classIdx: Int, numClasses: Int) -> String {
        if let custom = config.customLabels?[classIdx] { return custom }
        if numClasses == 80 || numClasses == 0 {
            if let name = Self.cocoFoodClasses[classIdx] { return name }
            if let name = Self.cocoDishClasses[classIdx]  { return name }
        }
        return "food_\(classIdx)"
    }
}

// MARK: - Error type

public enum YOLOv11Error: Error, LocalizedError {
    case modelNotFound(String)
    case unexpectedOutputShape

    public var errorDescription: String? {
        switch self {
        case .modelNotFound(let name):
            return "YOLOv11 CoreML model '\(name)' not found in app bundle. " +
                   "Export with: YOLO('yolo11n-seg.pt').export(format='coreml', nms=True) " +
                   "and drag the .mlpackage into Xcode."
        case .unexpectedOutputShape:
            return "YOLOv11 model output tensors have an unexpected shape. " +
                   "Ensure the model was exported with task='segment'."
        }
    }
}
