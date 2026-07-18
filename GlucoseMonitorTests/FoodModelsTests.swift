import XCTest
import CoreGraphics
@testable import GlucoseMonitor
#if canImport(UIKit)
import UIKit
#endif

/// Unit tests for FoodScanError, SegmentationResult, ScanState, and NutrientSummary.
/// Pure logic tests - no networking.
/// Pyramid layer: Unit (base).
final class FoodModelsTests: XCTestCase {

    // MARK: - FoodScanError.errorDescription

    func testErrorDescription_modelNotFound() {
        XCTAssertEqual(
            FoodScanError.modelNotFound.errorDescription,
            "FoodSegModel.mlmodelc not found in app bundle.")
    }

    func testErrorDescription_visionFailed_containsMessage() {
        let err = FoodScanError.visionFailed("inference timeout")
        XCTAssertTrue(err.errorDescription?.contains("Vision inference failed") == true)
        XCTAssertTrue(err.errorDescription?.contains("inference timeout") == true)
    }

    func testErrorDescription_noDepthData() {
        XCTAssertEqual(
            FoodScanError.noDepthData.errorDescription,
            "LiDAR depth data unavailable on this device.")
    }

    func testErrorDescription_apiError_containsMessage() {
        let err = FoodScanError.apiError("connection refused")
        XCTAssertTrue(err.errorDescription?.contains("Nutrition API error") == true)
        XCTAssertTrue(err.errorDescription?.contains("connection refused") == true)
    }

    func testErrorDescription_neverNil() {
        let cases: [FoodScanError] = [
            .modelNotFound, .visionFailed("x"), .noDepthData, .apiError("y")
        ]
        for err in cases {
            XCTAssertNotNil(err.errorDescription, "errorDescription must not be nil for \(err)")
        }
    }

    // MARK: - SegmentationResult.contains - bounds checking

    private func makeResult(width: Int, height: Int,
                            mask: [Bool]? = nil) -> SegmentationResult {
        let pixelMask = mask ?? [Bool](repeating: true, count: width * height)
        return SegmentationResult(
            label: "test", confidence: 0.9,
            boundingBox: CGRect(x: 0, y: 0, width: 1, height: 1),
            pixelMask: pixelMask, maskWidth: width, maskHeight: height,
            imageSize: CGSize(width: 640, height: 480))
    }

    private func makeResultWithSingleTruePixel(x px: Int, y py: Int,
                                               width: Int, height: Int) -> SegmentationResult {
        var mask = [Bool](repeating: false, count: width * height)
        mask[py * width + px] = true
        return makeResult(width: width, height: height, mask: mask)
    }

    func testContains_negativeX_returnsFalse() {
        XCTAssertFalse(makeResult(width: 10, height: 10).contains(maskX: -1, maskY: 0))
    }

    func testContains_negativeY_returnsFalse() {
        XCTAssertFalse(makeResult(width: 10, height: 10).contains(maskX: 0, maskY: -1))
    }

    func testContains_xEqualToWidth_returnsFalse() {
        // valid range is 0..<width; x == width is out of bounds
        XCTAssertFalse(makeResult(width: 10, height: 10).contains(maskX: 10, maskY: 0))
    }

    func testContains_yEqualToHeight_returnsFalse() {
        XCTAssertFalse(makeResult(width: 10, height: 10).contains(maskX: 0, maskY: 10))
    }

    func testContains_trueSinglePixel_returnsTrue() {
        let seg = makeResultWithSingleTruePixel(x: 2, y: 3, width: 5, height: 5)
        XCTAssertTrue(seg.contains(maskX: 2, maskY: 3))
    }

    func testContains_falsePixel_returnsFalse() {
        let seg = makeResultWithSingleTruePixel(x: 2, y: 3, width: 5, height: 5)
        XCTAssertFalse(seg.contains(maskX: 0, maskY: 0))
    }

    func testContains_allTrueMask_anyInteriorPixel_returnsTrue() {
        let seg = makeResult(width: 8, height: 6)  // all-true mask
        XCTAssertTrue(seg.contains(maskX: 4, maskY: 3))
    }

    func testContains_allTrueMask_cornerPixels_returnsTrue() {
        let seg = makeResult(width: 4, height: 4)
        XCTAssertTrue(seg.contains(maskX: 0, maskY: 0))
        XCTAssertTrue(seg.contains(maskX: 3, maskY: 3))
    }

    // MARK: - SegmentationResult.imageToMask - coordinate mapping

    private func makeResultForMapping(maskW: Int, maskH: Int,
                                      imgW: CGFloat, imgH: CGFloat) -> SegmentationResult {
        SegmentationResult(
            label: "test", confidence: 0.9, boundingBox: .zero,
            pixelMask: [Bool](repeating: false, count: maskW * maskH),
            maskWidth: maskW, maskHeight: maskH,
            imageSize: CGSize(width: imgW, height: imgH))
    }

    func testImageToMask_oneToOneMapping() {
        // 160×160 image, 160×160 mask -> pixel (80,80) maps to mask (80,80)
        let seg = makeResultForMapping(maskW: 160, maskH: 160, imgW: 160, imgH: 160)
        let (mx, my) = seg.imageToMask(imageX: 80, imageY: 80)
        XCTAssertEqual(mx, 80)
        XCTAssertEqual(my, 80)
    }

    func testImageToMask_scalesDown() {
        // 640×480 image mapped to 10×10 mask
        // imageX=320 (mid) -> 320/640 * 10 = 5
        // imageY=240 (mid) -> 240/480 * 10 = 5
        let seg = makeResultForMapping(maskW: 10, maskH: 10, imgW: 640, imgH: 480)
        let (mx, my) = seg.imageToMask(imageX: 320, imageY: 240)
        XCTAssertEqual(mx, 5)
        XCTAssertEqual(my, 5)
    }

    func testImageToMask_clampsAtLowerBound() {
        let seg = makeResultForMapping(maskW: 10, maskH: 10, imgW: 640, imgH: 480)
        let (mx, my) = seg.imageToMask(imageX: -999, imageY: -999)
        XCTAssertEqual(mx, 0)
        XCTAssertEqual(my, 0)
    }

    func testImageToMask_clampsAtUpperBound() {
        // imageX=640 = full width -> mask index clamped to maskWidth-1=9
        let seg = makeResultForMapping(maskW: 10, maskH: 10, imgW: 640, imgH: 480)
        let (mx, my) = seg.imageToMask(imageX: 640, imageY: 480)
        XCTAssertLessThanOrEqual(mx, 9)
        XCTAssertLessThanOrEqual(my, 9)
        XCTAssertGreaterThanOrEqual(mx, 0)
        XCTAssertGreaterThanOrEqual(my, 0)
    }

    // MARK: - ScanState custom equality

    func testScanState_idleEqualsIdle() {
        XCTAssertEqual(ScanState.idle, ScanState.idle)
    }

    func testScanState_idleNotEqualCapturing() {
        XCTAssertNotEqual(ScanState.idle, ScanState.capturing)
    }

    func testScanState_processingVisionEquality() {
        XCTAssertEqual(ScanState.processingVision, ScanState.processingVision)
    }

    func testScanState_fetchingNutrition_sameProgressAndTotal_equal() {
        XCTAssertEqual(
            ScanState.fetchingNutrition(progress: 3, total: 7),
            ScanState.fetchingNutrition(progress: 3, total: 7))
    }

    func testScanState_fetchingNutrition_differentProgress_notEqual() {
        XCTAssertNotEqual(
            ScanState.fetchingNutrition(progress: 1, total: 5),
            ScanState.fetchingNutrition(progress: 2, total: 5))
    }

    func testScanState_fetchingNutrition_differentTotal_notEqual() {
        XCTAssertNotEqual(
            ScanState.fetchingNutrition(progress: 2, total: 5),
            ScanState.fetchingNutrition(progress: 2, total: 6))
    }

    func testScanState_failedEqualsAnyFailed() {
        // Custom == treats all .failed as equal regardless of message
        XCTAssertEqual(ScanState.failed("error A"), ScanState.failed("error B"))
    }

    func testScanState_failedNotEqualIdle() {
        XCTAssertNotEqual(ScanState.failed("x"), ScanState.idle)
    }

    // MARK: - NutrientSummary computed properties

#if canImport(UIKit)

    private func makeComponent(label: String, massG: Double,
                               nutrients: NutrientData?) -> FoodComponent {
        FoodComponent(label: label, massG: massG,
                      volumeCm3: massG * 0.9, densityGCm3: 1.1,
                      boundingBox: .zero, nutrients: nutrients)
    }

    private func makeSummary(_ components: [FoodComponent]) -> NutrientSummary {
        NutrientSummary(components: components,
                        capturedImage: UIImage(),
                        capturedAt: Date())
    }

    func testNutrientSummary_empty_allZeroOrNil() {
        let s = makeSummary([])
        XCTAssertEqual(s.totalCalories,  0)
        XCTAssertEqual(s.totalCarbsG,    0)
        XCTAssertEqual(s.totalProteinG,  0)
        XCTAssertEqual(s.totalFatG,      0)
        XCTAssertEqual(s.totalGL,        0)
        XCTAssertNil(s.averageGI,        "averageGI must be nil when no components have a GI")
        XCTAssertEqual(s.noteDescription, "")
    }

    func testNutrientSummary_totalCaloriesSumsComponents() {
        let n1 = NutrientData(calories: 200, proteinG: 10, fatG:  5, carbsG: 30, glycemicIndex: 50)
        let n2 = NutrientData(calories: 300, proteinG: 15, fatG:  8, carbsG: 45, glycemicIndex: 60)
        let s = makeSummary([
            makeComponent(label: "rice",    massG: 100, nutrients: n1),
            makeComponent(label: "chicken", massG: 150, nutrients: n2)
        ])
        XCTAssertEqual(s.totalCalories, 500, accuracy: 0.01)
    }

    func testNutrientSummary_nilNutrients_notCountedInTotals() {
        let n = NutrientData(calories: 200, proteinG: 10, fatG: 5, carbsG: 30, glycemicIndex: 50)
        let s = makeSummary([
            makeComponent(label: "known",   massG: 100, nutrients: n),
            makeComponent(label: "unknown", massG: 100, nutrients: nil)
        ])
        XCTAssertEqual(s.totalCalories, 200, accuracy: 0.01,
            "Component with nil nutrients must not contribute to totalCalories")
    }

    func testNutrientSummary_averageGI_calculatedCorrectly() {
        let n1 = NutrientData(calories: 200, proteinG: 5, fatG: 2, carbsG: 40, glycemicIndex: 60)
        let n2 = NutrientData(calories: 100, proteinG: 3, fatG: 1, carbsG: 20, glycemicIndex: 40)
        let s = makeSummary([
            makeComponent(label: "a", massG: 100, nutrients: n1),
            makeComponent(label: "b", massG:  80, nutrients: n2)
        ])
        // averageGI = (60 + 40) / 2 = 50
        XCTAssertEqual(s.averageGI!, 50.0, accuracy: 0.01)
    }

    func testNutrientSummary_averageGI_nilWhenNoComponentHasGI() {
        let n = NutrientData(calories: 155, proteinG: 13, fatG: 11, carbsG: 1, glycemicIndex: nil)
        let s = makeSummary([makeComponent(label: "egg", massG: 50, nutrients: n)])
        XCTAssertNil(s.averageGI)
    }

    func testNutrientSummary_noteDescription_containsLabelsAndMass() {
        let s = makeSummary([
            makeComponent(label: "rice",    massG: 120, nutrients: nil),
            makeComponent(label: "chicken", massG:  80, nutrients: nil)
        ])
        XCTAssertTrue(s.noteDescription.contains("rice"))
        XCTAssertTrue(s.noteDescription.contains("chicken"))
        XCTAssertTrue(s.noteDescription.contains("120g"))
        XCTAssertTrue(s.noteDescription.contains("80g"))
    }

    func testScanState_done_equalsAnyDone() {
        // Custom == treats all .done as equal regardless of payload
        let s1 = NutrientSummary(components: [], capturedImage: UIImage(), capturedAt: Date())
        let s2 = NutrientSummary(components: [], capturedImage: UIImage(), capturedAt: Date())
        XCTAssertEqual(ScanState.done(s1), ScanState.done(s2))
    }

#endif
}
