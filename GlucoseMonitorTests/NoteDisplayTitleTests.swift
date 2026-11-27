import XCTest
@testable import GlucoseMonitor

final class NoteDisplayTitleTests: XCTestCase {

    func testGenericMealUsesNormalizedFoods() throws {
        let profile = #"{"normalizedFoods":["buckwheat 200 g","grape 100 g","milk"]}"#
        let note = try decodeNote(meal: "Meal", comment: nil, nutritionProfile: profile)
        XCTAssertEqual(note.displayTitle, "buckwheat, grape, milk")
    }

    func testGenericMealFallsBackToCommentDescription() throws {
        let note = try decodeNote(meal: "Meal", comment: "150 g buckwheat, grape 100 g", nutritionProfile: nil)
        XCTAssertEqual(note.displayTitle, "buckwheat, grape")
    }

    func testMealTypeDefersToDescription() throws {
        let note = try decodeNote(meal: "Lunch", comment: "buckwheat", nutritionProfile: nil)
        XCTAssertEqual(note.displayTitle, "buckwheat")
    }

    func testMealTypeKeptWithoutDescription() throws {
        let note = try decodeNote(meal: "Correction", comment: nil, nutritionProfile: nil)
        XCTAssertEqual(note.displayTitle, "Correction")
    }

    func testStoredFoodNamesUsedAsMeal() throws {
        let note = try decodeNote(meal: "buckwheat, grape, milk", comment: nil, nutritionProfile: nil)
        XCTAssertEqual(note.displayTitle, "buckwheat, grape, milk")
    }

    private func decodeNote(meal: String, comment: String?, nutritionProfile: String?) throws -> BackendAPI.GlucoseNote {
        var obj: [String: Any] = [
            "id": "n1",
            "carbs": 40.0,
            "insulin": 0.0,
            "meal": meal
        ]
        if let comment { obj["comment"] = comment }
        if let nutritionProfile { obj["nutritionProfile"] = nutritionProfile }
        let data = try JSONSerialization.data(withJSONObject: obj)
        return try GlucoseMonitorAPI.jsonDecoder().decode(BackendAPI.GlucoseNote.self, from: data)
    }
}
