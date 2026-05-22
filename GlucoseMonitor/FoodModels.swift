import Foundation
import CoreGraphics

// NutrientData is defined in NutritionAPIService.swift (Foundation-only, no ARKit/UIKit)
// so SourceKit can resolve it from any file in the module.

// MARK: - Food Component

/// One recognised food item with its physical measurements and optional nutrition data.
public struct FoodComponent: Identifiable {
    public let id:          UUID
    public let label:       String
    public let massG:       Double
    public let volumeCm3:   Double
    public let densityGCm3: Double
    /// Normalised bounding box in image coordinates [0, 1] (origin = top-left).
    public let boundingBox: CGRect
    /// Populated with local USDA nutrition data; nil only when enrichment is skipped.
    public let nutrients:   NutrientData?

    public init(id: UUID = UUID(), label: String, massG: Double,
                volumeCm3: Double, densityGCm3: Double,
                boundingBox: CGRect, nutrients: NutrientData?) {
        self.id = id;  self.label = label
        self.massG = massG;  self.volumeCm3 = volumeCm3;  self.densityGCm3 = densityGCm3
        self.boundingBox = boundingBox;  self.nutrients = nutrients
    }
}

// MARK: - Segmentation Result (Vision output)

public struct SegmentationResult {
    public let label:       String
    public let confidence:  Float
    /// Normalised bounding box [0, 1] image coordinates.
    public let boundingBox: CGRect
    /// Binary mask at `maskWidth × maskHeight` resolution (typically 160 × 160).
    public let pixelMask:   [Bool]
    public let maskWidth:   Int
    public let maskHeight:  Int
    public let imageSize:   CGSize

    @inline(__always)
    public func contains(maskX: Int, maskY: Int) -> Bool {
        guard maskX >= 0, maskX < maskWidth,
              maskY >= 0, maskY < maskHeight else { return false }
        return pixelMask[maskY * maskWidth + maskX]
    }

    /// Map an image-space pixel to the nearest mask-space coordinate.
    @inline(__always)
    public func imageToMask(imageX: Int, imageY: Int) -> (x: Int, y: Int) {
        let mx = (Int(Double(imageX) / imageSize.width  * Double(maskWidth)))
            .clamped(to: 0..<maskWidth)
        let my = (Int(Double(imageY) / imageSize.height * Double(maskHeight)))
            .clamped(to: 0..<maskHeight)
        return (mx, my)
    }
}

private extension Int {
    func clamped(to range: Range<Int>) -> Int {
        Swift.max(range.lowerBound, Swift.min(self, range.upperBound - 1))
    }
}

// MARK: - Errors

public enum FoodScanError: LocalizedError {
    case modelNotFound
    case visionFailed(String)
    case noDepthData
    case apiError(String)

    public var errorDescription: String? {
        switch self {
        case .modelNotFound:       return "FoodSegModel.mlmodelc not found in app bundle."
        case .visionFailed(let m): return "Vision inference failed: \(m)"
        case .noDepthData:         return "LiDAR depth data unavailable on this device."
        case .apiError(let m):     return "Nutrition API error: \(m)"
        }
    }
}
