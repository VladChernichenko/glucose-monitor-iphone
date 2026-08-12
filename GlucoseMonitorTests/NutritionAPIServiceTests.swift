import XCTest
@testable import GlucoseMonitor

/// Unit tests for NutrientData.glycemicLoad and NutritionAPIService.fetchNutrition.
/// Pure business logic - no networking, no I/O.
/// Pyramid layer: Unit (base).
final class NutritionAPIServiceTests: XCTestCase {

    private let service = NutritionAPIService()

    // MARK: - NutrientData.glycemicLoad

    func testGlycemicLoad_nilGI_returnsNil() {
        let data = NutrientData(calories: 155, proteinG: 13, fatG: 11,
                                carbsG: 1.1, glycemicIndex: nil)
        XCTAssertNil(data.glycemicLoad,
            "GL must be nil when glycemicIndex is nil (non-carbohydrate food)")
    }

    func testGlycemicLoad_standardCalculation() {
        // GL = (GI × carbs g) / 100 = (55 × 100) / 100 = 55.0
        let data = NutrientData(calories: 347, proteinG: 5, fatG: 13,
                                carbsG: 100, glycemicIndex: 55)
        XCTAssertEqual(data.glycemicLoad!, 55.0, accuracy: 0.001)
    }

    func testGlycemicLoad_partialCarbs() {
        // GL = (70 × 50) / 100 = 35.0
        let data = NutrientData(calories: 400, proteinG: 0, fatG: 0.5,
                                carbsG: 50, glycemicIndex: 70)
        XCTAssertEqual(data.glycemicLoad!, 35.0, accuracy: 0.001)
    }

    func testGlycemicLoad_zeroCarbs_yieldsZeroGL() {
        // Even with a GI, zero carbs -> GL = 0
        let data = NutrientData(calories: 155, proteinG: 13, fatG: 11,
                                carbsG: 0, glycemicIndex: 40)
        XCTAssertEqual(data.glycemicLoad!, 0.0, accuracy: 0.001)
    }

    func testGlycemicLoad_lowGI_lowCarbs() {
        // GI=15 (almond), carbs=22g per 100g -> GL = (15 × 22) / 100 = 3.3
        let data = NutrientData(calories: 579, proteinG: 21, fatG: 50,
                                carbsG: 22, glycemicIndex: 15)
        XCTAssertEqual(data.glycemicLoad!, 3.3, accuracy: 0.01)
    }

    // MARK: - NutritionAPIService.fetchNutrition - exact label match

    func testFetchNutrition_chocolate_exactMatch() {
        // Table entry: "chocolate": (546, 60.0, 5.0, 31.0, 40) per 100g
        let result = service.fetchNutrition(label: "chocolate", massG: 100)
        XCTAssertEqual(result.calories,      546, accuracy: 0.1)
        XCTAssertEqual(result.carbsG,         60, accuracy: 0.1)
        XCTAssertEqual(result.proteinG,        5, accuracy: 0.1)
        XCTAssertEqual(result.fatG,           31, accuracy: 0.1)
        XCTAssertEqual(result.glycemicIndex!, 40, accuracy: 0.1)
    }

    func testFetchNutrition_caseInsensitive() {
        let lower  = service.fetchNutrition(label: "chocolate",  massG: 100)
        let upper  = service.fetchNutrition(label: "CHOCOLATE",  massG: 100)
        let mixed  = service.fetchNutrition(label: "Chocolate",  massG: 100)
        XCTAssertEqual(lower.calories, upper.calories, accuracy: 0.01)
        XCTAssertEqual(lower.calories, mixed.calories, accuracy: 0.01)
    }

    // MARK: - Mass scaling

    func testFetchNutrition_doublingMass_doublesCaloriesAndMacros() {
        let base   = service.fetchNutrition(label: "chocolate", massG: 100)
        let double = service.fetchNutrition(label: "chocolate", massG: 200)
        XCTAssertEqual(double.calories, base.calories * 2, accuracy: 0.01)
        XCTAssertEqual(double.carbsG,   base.carbsG   * 2, accuracy: 0.01)
        XCTAssertEqual(double.proteinG, base.proteinG * 2, accuracy: 0.01)
        XCTAssertEqual(double.fatG,     base.fatG     * 2, accuracy: 0.01)
    }

    func testFetchNutrition_glycemicIndexNotScaledWithMass() {
        // GI is a property of the food, not the serving size
        let small = service.fetchNutrition(label: "chocolate", massG: 30)
        let large = service.fetchNutrition(label: "chocolate", massG: 250)
        XCTAssertEqual(small.glycemicIndex!, large.glycemicIndex!, accuracy: 0.001)
    }

    func testFetchNutrition_zeroMass_returnsZeroNutrients() {
        let result = service.fetchNutrition(label: "chocolate", massG: 0)
        XCTAssertEqual(result.calories, 0, accuracy: 0.001)
        XCTAssertEqual(result.carbsG,   0, accuracy: 0.001)
        XCTAssertEqual(result.proteinG, 0, accuracy: 0.001)
        XCTAssertEqual(result.fatG,     0, accuracy: 0.001)
    }

    // MARK: - Unknown label -> generic fallback

    func testFetchNutrition_unknownLabel_usesGenericFallback() {
        // Fallback: 150 kcal, 20g carbs, 8g protein, 5g fat, GI=50 per 100g
        let result = service.fetchNutrition(label: "xyzabsolutelyunknown999", massG: 100)
        XCTAssertEqual(result.calories, 150, accuracy: 0.1)
        XCTAssertEqual(result.carbsG,    20, accuracy: 0.1)
        XCTAssertEqual(result.proteinG,   8, accuracy: 0.1)
        XCTAssertEqual(result.fatG,       5, accuracy: 0.1)
        XCTAssertEqual(result.glycemicIndex!, 50, accuracy: 0.1)
    }

    // MARK: - Substring match

    func testFetchNutrition_substringMatch_findsLongestKey() {
        // "dark chocolate" contains "chocolate" -> substring match returns chocolate entry
        let darkChoc  = service.fetchNutrition(label: "dark chocolate",  massG: 100)
        let chocolate  = service.fetchNutrition(label: "chocolate",       massG: 100)
        // The matched entry should NOT be the generic fallback
        XCTAssertNotEqual(darkChoc.calories, 150, accuracy: 1,
            "Substring match should hit 'chocolate' (546 kcal), not the generic fallback (150 kcal)")
        XCTAssertEqual(darkChoc.calories, chocolate.calories, accuracy: 0.1)
    }

    func testFetchNutrition_partialMatch_notEqualToFallback() {
        // "almond cake" contains "almond" and "cake" - at least one key should match
        let result = service.fetchNutrition(label: "almond cake", massG: 100)
        XCTAssertNotEqual(result.calories, 150, accuracy: 1,
            "A label with known substrings must not fall through to the generic 150 kcal fallback")
    }
}
