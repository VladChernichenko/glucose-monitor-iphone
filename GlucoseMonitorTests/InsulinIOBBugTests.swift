import XCTest
@testable import GlucoseMonitor

/// Regression tests for IOB-related bugs.
/// These tests fail against the BUGGY code and pass once each bug is fixed.
final class InsulinIOBBugTests: XCTestCase {

    // MARK: - Helpers (mirrors InsulinIOBTests.makeNote)

    private func makeNote(insulin: Double, minsAgo: Double) -> BackendAPI.GlucoseNote {
        BackendAPI.GlucoseNote(
            id: UUID().uuidString,
            timestamp: Date(timeIntervalSinceNow: -minsAgo * 60),
            carbs: 0, insulin: insulin, meal: "Correction",
            comment: nil, glucoseValue: nil, absorptionMode: nil, photoUrl: nil)
    }

    // MARK: - iOS-4: DIA duration must be 4.5 h to match the backend default

    // BUG: iOS-4 — DIA hardcoded to 4.0 instead of reading from user settings (backend uses 4.5h default)
    // CURRENT STATUS: FIXED (durationHours = 4.5 in InsulinIOB.swift).
    // This test is a REGRESSION GUARD — it will start failing again if the value is reverted to 4.0.
    func testDurationHoursIs4Point5() {
        // A dose given exactly 240 minutes (4 hours) ago:
        //   With DIA = 4.5 h (270 min), minsAgo=240 is inside the window → IOB > 0.
        //   With DIA = 4.0 h (240 min), the guard `minsAgo >= end` fires at minsAgo==240 → IOB == 0.
        let note = makeNote(insulin: 5, minsAgo: 4 * 60)    // 240 min ago
        let iob = InsulinIOB.currentIOBFromNotes(notes: [note])
        XCTAssertGreaterThan(
            iob, 0,
            "IOB must be > 0 at t=240 min when DIA=4.5h (270 min window). "
            + "Zero means DIA was reverted to 4.0h — the iOS-4 bug is back.")
    }

    // BUG: iOS-4 — a dose at 269 min (just inside the 4.5h window) must still show IOB > 0
    func testDurationHours_justInsideWindow() {
        // 269 min < 270 min (4.5 h * 60) → should still have residual IOB
        let note = makeNote(insulin: 10, minsAgo: 269)
        let iob = InsulinIOB.currentIOBFromNotes(notes: [note])
        XCTAssertGreaterThan(
            iob, 0,
            "A dose 269 min ago must still have IOB with a 4.5h DIA (270 min window)")
    }

    // BUG: iOS-4 — a dose at exactly 270 min (the end of the 4.5h window) must be zero
    func testDurationHours_atExactWindowBoundary_isZero() {
        // minsAgo == end → guard fires → IOB == 0
        let note = makeNote(insulin: 10, minsAgo: 270)
        let iob = InsulinIOB.currentIOBFromNotes(notes: [note])
        XCTAssertEqual(
            iob, 0,
            "A dose exactly at the 4.5h boundary (270 min) must have zero IOB (cleared)")
    }
}
