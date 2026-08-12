import XCTest
@testable import GlucoseMonitor

/// Regression tests for editing an existing note: opening it for edit only populated the
/// carbs slider - protein, fat and fiber were hardcoded to 0 instead of being read from
/// the note's stored `nutritionProfile`.
/// CURRENT STATUS: FIXED via BackendAPI.initialMacroValues(from:), used by EditNoteSheet.init.
/// These tests are REGRESSION GUARDS.
final class EditNoteNutritionProfileTests: XCTestCase {

    private func makeNote(nutritionProfile: String?) -> BackendAPI.GlucoseNote {
        BackendAPI.GlucoseNote(
            id: "1", timestamp: Date(), carbs: 30, insulin: 2, meal: "Lunch",
            comment: nil, glucoseValue: nil, absorptionMode: nil,
            nutritionProfile: nutritionProfile, photoUrl: nil)
    }

    // MARK: - parseNutritionProfile

    func testParseNutritionProfile_nilInput_returnsNil() {
        XCTAssertNil(BackendAPI.parseNutritionProfile(nil))
    }

    func testParseNutritionProfile_invalidJSON_returnsNil() {
        XCTAssertNil(BackendAPI.parseNutritionProfile("not json"))
    }

    func testParseNutritionProfile_fullJSON_decodesMacros() {
        let json = #"{"totalCarbs": 35, "protein": 12, "fat": 18, "fiber": 7}"#
        let snap = BackendAPI.parseNutritionProfile(json)
        XCTAssertEqual(snap?.totalCarbs, 35)
        XCTAssertEqual(snap?.protein, 12)
        XCTAssertEqual(snap?.fat, 18)
        XCTAssertEqual(snap?.fiber, 7)
    }

    func testParseNutritionProfile_partialJSON_missingFieldsAreNil() {
        let json = #"{"protein": 12}"#
        let snap = BackendAPI.parseNutritionProfile(json)
        XCTAssertEqual(snap?.protein, 12)
        XCTAssertNil(snap?.fat)
        XCTAssertNil(snap?.fiber)
        XCTAssertNil(snap?.totalCarbs)
    }

    // MARK: - initialMacroValues (EditNoteSheet pre-population)

    // BUG: opening an existing note for editing only showed carbs - protein/fat/fiber
    // were hardcoded to 0 instead of being read from note.nutritionProfile.
    func testInitialMacroValues_populatesFromStoredNutritionProfile() {
        let note = makeNote(nutritionProfile:
            #"{"totalCarbs": 35, "protein": 15, "fat": 20, "fiber": 6}"#)
        let macros = BackendAPI.initialMacroValues(from: note)
        XCTAssertEqual(macros.protein, 15)
        XCTAssertEqual(macros.fat, 20)
        XCTAssertEqual(macros.fiber, 6)
    }

    func testInitialMacroValues_noNutritionProfile_returnsZero() {
        let note = makeNote(nutritionProfile: nil)
        let macros = BackendAPI.initialMacroValues(from: note)
        XCTAssertEqual(macros.protein, 0)
        XCTAssertEqual(macros.fat, 0)
        XCTAssertEqual(macros.fiber, 0)
    }

    func testInitialMacroValues_invalidJSON_returnsZero() {
        let note = makeNote(nutritionProfile: "not json")
        let macros = BackendAPI.initialMacroValues(from: note)
        XCTAssertEqual(macros.protein, 0)
        XCTAssertEqual(macros.fat, 0)
        XCTAssertEqual(macros.fiber, 0)
    }

    // Protein/fat snap to 5g steps, matching the slider's step size.
    func testInitialMacroValues_proteinAndFatSnapToFiveGramSteps() {
        let note = makeNote(nutritionProfile: #"{"protein": 12, "fat": 18}"#)
        let macros = BackendAPI.initialMacroValues(from: note)
        XCTAssertEqual(macros.protein, 10, "12g should round to the nearest 5g step (10)")
        XCTAssertEqual(macros.fat, 20, "18g should round to the nearest 5g step (20)")
    }

    // Fiber snaps to 1g steps, matching the slider's step size.
    func testInitialMacroValues_fiberRoundsToNearestGram() {
        let note = makeNote(nutritionProfile: #"{"fiber": 6.6}"#)
        let macros = BackendAPI.initialMacroValues(from: note)
        XCTAssertEqual(macros.fiber, 7)
    }

    // Values above the slider range must be clamped, not overflow the slider.
    func testInitialMacroValues_clampsToSliderRange() {
        let note = makeNote(nutritionProfile: #"{"protein": 250, "fat": 999, "fiber": 80}"#)
        let macros = BackendAPI.initialMacroValues(from: note)
        XCTAssertEqual(macros.protein, 100, "protein must be clamped to the 0...100 slider range")
        XCTAssertEqual(macros.fat, 100, "fat must be clamped to the 0...100 slider range")
        XCTAssertEqual(macros.fiber, 50, "fiber must be clamped to the 0...50 slider range")
    }

    // Negative values must clamp to 0, not produce negative slider positions.
    func testInitialMacroValues_negativeValuesClampToZero() {
        let note = makeNote(nutritionProfile: #"{"protein": -5, "fat": -1, "fiber": -2}"#)
        let macros = BackendAPI.initialMacroValues(from: note)
        XCTAssertEqual(macros.protein, 0)
        XCTAssertEqual(macros.fat, 0)
        XCTAssertEqual(macros.fiber, 0)
    }

    // MARK: - Round trip with macroNutritionProfileJson (manually-entered macros)

    // A note saved with manually-entered macros (already on step boundaries) must restore
    // the exact same slider values when reopened for edit.
    func testInitialMacroValues_roundTripsWithMacroNutritionProfileJson() {
        let json = BackendAPI.macroNutritionProfileJson(carbs: 35, protein: 15, fat: 20, fiber: 6)
        let note = makeNote(nutritionProfile: json)
        let macros = BackendAPI.initialMacroValues(from: note)
        XCTAssertEqual(macros.protein, 15)
        XCTAssertEqual(macros.fat, 20)
        XCTAssertEqual(macros.fiber, 6)
    }

    // macroNutritionProfileJson omits zero macros entirely - reopening must show 0, not crash.
    func testInitialMacroValues_roundTripsWithZeroMacros() {
        let json = BackendAPI.macroNutritionProfileJson(carbs: 35, protein: 0, fat: 0, fiber: 0)
        let note = makeNote(nutritionProfile: json)
        let macros = BackendAPI.initialMacroValues(from: note)
        XCTAssertEqual(macros.protein, 0)
        XCTAssertEqual(macros.fat, 0)
        XCTAssertEqual(macros.fiber, 0)
    }
}
