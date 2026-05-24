import XCTest
@testable import GlucoseMonitor

/// Unit tests for PreBolusTimer.state() — pure business logic, no networking, no UI.
/// Pyramid layer: Unit (base).
final class PreBolusTimerTests: XCTestCase {

    // MARK: - Helpers

    private func makeNote(meal: String, insulin: Double, carbs: Double,
                          at date: Date) -> BackendAPI.GlucoseNote {
        BackendAPI.GlucoseNote(
            id: UUID().uuidString, timestamp: date,
            carbs: carbs, insulin: insulin, meal: meal,
            comment: nil, glucoseValue: nil, absorptionMode: nil, photoUrl: nil)
    }

    // MARK: - Not visible: no matching pre-bolus note

    func testNoNotes_notVisible() {
        let (visible, label) = PreBolusTimer.state(notes: [], now: Date())
        XCTAssertFalse(visible)
        XCTAssertEqual(label, "--")
    }

    func testOnlyCorrectionNotes_notVisible() {
        let now = Date()
        let notes = [makeNote(meal: "Correction", insulin: 2, carbs: 0, at: now.addingTimeInterval(-300))]
        let (visible, _) = PreBolusTimer.state(notes: notes, now: now)
        XCTAssertFalse(visible)
    }

    func testPreBolusWithZeroInsulin_notVisible() {
        // insulin = 0 is filtered out by the guard
        let now = Date()
        let notes = [makeNote(meal: "pre-bolus", insulin: 0, carbs: 0, at: now.addingTimeInterval(-300))]
        let (visible, _) = PreBolusTimer.state(notes: notes, now: now)
        XCTAssertFalse(visible)
    }

    func testPreBolusWithNilTimestamp_notVisible() {
        let note = BackendAPI.GlucoseNote(
            id: "1", timestamp: nil, carbs: 0, insulin: 3, meal: "pre-bolus",
            comment: nil, glucoseValue: nil, absorptionMode: nil, photoUrl: nil)
        let (visible, _) = PreBolusTimer.state(notes: [note], now: Date())
        XCTAssertFalse(visible)
    }

    // MARK: - Not visible: meal note after bolus hides the timer

    func testPreBolusFollowedByMeal_notVisible() {
        let now = Date()
        let bolus = now.addingTimeInterval(-600)  // 10 min ago
        let meal  = now.addingTimeInterval(-300)  // 5 min ago
        let notes = [
            makeNote(meal: "pre-bolus", insulin: 4, carbs: 0,  at: bolus),
            makeNote(meal: "Breakfast",  insulin: 0, carbs: 60, at: meal)
        ]
        let (visible, _) = PreBolusTimer.state(notes: notes, now: now)
        XCTAssertFalse(visible)
    }

    func testMealNoteBeforeBolus_doesNotHide() {
        // Meal timestamp is BEFORE the bolus — must NOT hide the timer
        let now = Date()
        let meal  = now.addingTimeInterval(-900)   // 15 min ago
        let bolus = now.addingTimeInterval(-600)   // 10 min ago (after meal)
        let notes = [
            makeNote(meal: "Lunch",     insulin: 0, carbs: 50, at: meal),
            makeNote(meal: "pre-bolus", insulin: 4, carbs: 0,  at: bolus)
        ]
        let (visible, _) = PreBolusTimer.state(notes: notes, now: now)
        XCTAssertTrue(visible)
    }

    func testMealWithZeroCarbs_doesNotHide() {
        // Meal note after bolus but carbs == 0 → timer stays visible
        let now = Date()
        let bolus = now.addingTimeInterval(-600)
        let meal  = now.addingTimeInterval(-300)
        let notes = [
            makeNote(meal: "pre-bolus", insulin: 4, carbs: 0, at: bolus),
            makeNote(meal: "Breakfast",  insulin: 0, carbs: 0, at: meal)   // no carbs
        ]
        let (visible, _) = PreBolusTimer.state(notes: notes, now: now)
        XCTAssertTrue(visible)
    }

    func testCorrectionAfterBolus_doesNotHide() {
        // "correction" meal type is excluded from the meal-detection check
        let now = Date()
        let bolus = now.addingTimeInterval(-600)
        let corr  = now.addingTimeInterval(-300)
        let notes = [
            makeNote(meal: "pre-bolus",  insulin: 4, carbs: 0, at: bolus),
            makeNote(meal: "correction", insulin: 1, carbs: 0, at: corr)
        ]
        let (visible, _) = PreBolusTimer.state(notes: notes, now: now)
        XCTAssertTrue(visible)
    }

    // MARK: - Visible: timer shows elapsed time

    func testPreBolusNote_isVisible() {
        let now = Date()
        let notes = [makeNote(meal: "pre-bolus", insulin: 3, carbs: 0, at: now.addingTimeInterval(-300))]
        let (visible, _) = PreBolusTimer.state(notes: notes, now: now)
        XCTAssertTrue(visible)
    }

    func testPrebolusAlias_isVisible() {
        // "prebolus" without hyphen is also a valid trigger
        let now = Date()
        let notes = [makeNote(meal: "prebolus", insulin: 3, carbs: 0, at: now.addingTimeInterval(-300))]
        let (visible, _) = PreBolusTimer.state(notes: notes, now: now)
        XCTAssertTrue(visible)
    }

    func testPreBolusNote_caseInsensitive() {
        let now = Date()
        let notes = [makeNote(meal: "Pre-Bolus", insulin: 3, carbs: 0, at: now.addingTimeInterval(-300))]
        let (visible, _) = PreBolusTimer.state(notes: notes, now: now)
        XCTAssertTrue(visible)
    }

    // MARK: - Label formatting

    func testLabel_ninetySeconds_oneThirty() {
        let now   = Date()
        let bolus = now.addingTimeInterval(-90)   // exactly 90 s before 'now'
        let notes = [makeNote(meal: "pre-bolus", insulin: 3, carbs: 0, at: bolus)]
        let (_, label) = PreBolusTimer.state(notes: notes, now: now)
        XCTAssertEqual(label, "1:30")
    }

    func testLabel_subMinute_zeroPaddedSeconds() {
        let now   = Date()
        let bolus = now.addingTimeInterval(-45)
        let notes = [makeNote(meal: "pre-bolus", insulin: 3, carbs: 0, at: bolus)]
        let (_, label) = PreBolusTimer.state(notes: notes, now: now)
        XCTAssertEqual(label, "0:45")
    }

    func testLabel_exactlyTwoMinutes() {
        let now   = Date()
        let bolus = now.addingTimeInterval(-120)
        let notes = [makeNote(meal: "pre-bolus", insulin: 3, carbs: 0, at: bolus)]
        let (_, label) = PreBolusTimer.state(notes: notes, now: now)
        XCTAssertEqual(label, "2:00")
    }

    // MARK: - Multiple pre-bolus notes: latest wins

    func testMultiplePreBolus_latestWins() {
        let now   = Date()
        let older = now.addingTimeInterval(-600)  // 10 min ago
        let newer = now.addingTimeInterval(-120)  // 2 min ago
        let notes = [
            makeNote(meal: "pre-bolus", insulin: 2, carbs: 0, at: older),
            makeNote(meal: "pre-bolus", insulin: 3, carbs: 0, at: newer)
        ]
        let (visible, label) = PreBolusTimer.state(notes: notes, now: now)
        XCTAssertTrue(visible)
        XCTAssertEqual(label, "2:00")   // elapsed from newer note
    }

    func testMultiplePreBolus_latestFollowedByMeal_notVisible() {
        // Latest pre-bolus was followed by a meal → hidden (even though an older bolus exists)
        let now   = Date()
        let older = now.addingTimeInterval(-900)
        let newer = now.addingTimeInterval(-600)
        let meal  = now.addingTimeInterval(-300)
        let notes = [
            makeNote(meal: "pre-bolus", insulin: 2, carbs: 0,  at: older),
            makeNote(meal: "pre-bolus", insulin: 3, carbs: 0,  at: newer),
            makeNote(meal: "Lunch",     insulin: 0, carbs: 50, at: meal)
        ]
        let (visible, _) = PreBolusTimer.state(notes: notes, now: now)
        XCTAssertFalse(visible)
    }
}
