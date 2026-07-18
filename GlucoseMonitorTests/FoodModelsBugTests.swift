import XCTest
@testable import GlucoseMonitor

/// Regression tests for FoodModels / BackendAPI.NutritionSnapshot bugs.
///
/// FoodMassBreakdown is defined as a nested struct inside BackendAPI.NutritionSnapshot
/// (BackendAPI.swift, line ~311):
///
///     struct FoodMassBreakdown: Decodable, Identifiable {
///         var id: String { label ?? UUID().uuidString }
///         let label: String?
///         ...
///     }
///
/// The `id` property is a COMPUTED property: when `label` is nil it calls `UUID()` every
/// time it is accessed, returning a different value on each call.  SwiftUI uses `id` to
/// track list rows; a non-stable id causes rows to flicker and lose state.
final class FoodModelsBugTests: XCTestCase {

    // MARK: - I2: FoodMassBreakdown.id must be stable across accesses

    // BUG: I2 - FoodMassBreakdown.id computed property returns new UUID() on every access
    // when label is nil.  After fix: id should be a stored property so it returns the same
    // value on every call.
    // CURRENT STATUS: NOT FIXED - id is still a computed var returning UUID() when label is nil.
    // This test CURRENTLY FAILS and should pass once the fix is applied.
    func testFoodMassBreakdown_idIsStable_whenLabelIsPresent() {
        // When a label is present, id returns label on every call -> already stable.
        // This sub-case passes even before the fix.
        let item = makeItem(label: "Rice")
        let id1 = item.id
        let id2 = item.id
        XCTAssertEqual(
            id1, id2,
            "I2: id must be the same String on repeated accesses when label is present")
        XCTAssertEqual(id1, "Rice", "id must equal the label string")
    }

    // BUG: I2 - FoodMassBreakdown.id returns a NEW UUID() on every access when label is nil
    // CURRENT STATUS: NOT FIXED.  This test CURRENTLY FAILS.
    func testFoodMassBreakdown_idIsStable_whenLabelIsNil() {
        // When label is nil, the current implementation is:
        //   var id: String { label ?? UUID().uuidString }
        // -> UUID() is called anew on each property access -> id1 != id2
        //
        // After the fix (stored let id = UUID().uuidString or injected in init),
        // id1 and id2 must be equal.
        let item = makeItem(label: nil)
        let id1 = item.id
        let id2 = item.id
        XCTAssertEqual(
            id1, id2,
            "I2: FoodMassBreakdown.id must return the same value on every access even when "
            + "label is nil. Currently `var id: String { label ?? UUID().uuidString }` "
            + "generates a new UUID on each call - fix by using a stored property.")
    }

    // BUG: I2 - Two different items with nil labels must have DIFFERENT stable ids
    // (so SwiftUI can distinguish them in a list).
    func testFoodMassBreakdown_twoNilLabelItems_haveDifferentIds() {
        let item1 = makeItem(label: nil)
        let item2 = makeItem(label: nil)
        // Each item must have its own stable id.
        // Before fix: they'd always return different UUIDs per call (accidentally passes),
        // but the id is still unstable within the same item across accesses.
        // After fix with a stored property, this is naturally satisfied.
        XCTAssertNotEqual(
            item1.id, item2.id,
            "I2: Two distinct FoodMassBreakdown items must have different ids")
        // Stability check for each item individually
        XCTAssertEqual(item1.id, item1.id, "item1.id must be stable")
        XCTAssertEqual(item2.id, item2.id, "item2.id must be stable")
    }

    // MARK: - Helpers

    /// Construct a FoodMassBreakdown via JSON decoding (it is Decodable, not directly init-able).
    private func makeItem(label: String?) -> BackendAPI.NutritionSnapshot.FoodMassBreakdown {
        let labelJSON: String
        if let l = label {
            labelJSON = "\"\(l)\""
        } else {
            labelJSON = "null"
        }
        let json = """
        {
            "label": \(labelJSON),
            "massG": 100,
            "carbs": 25,
            "fat": 1,
            "protein": 3,
            "fiber": 2,
            "gi": 55,
            "offProductName": null,
            "confidence": 0.9
        }
        """.data(using: .utf8)!
        return try! JSONDecoder().decode(
            BackendAPI.NutritionSnapshot.FoodMassBreakdown.self, from: json)
    }
}
