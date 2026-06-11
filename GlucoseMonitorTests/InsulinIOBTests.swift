import XCTest
@testable import GlucoseMonitor

/// Tests for the OpenAPS exponential IOB curve and note-based IOB aggregation.
/// All inputs are deterministic — no async, no networking.
final class InsulinIOBTests: XCTestCase {

    // MARK: - iobOpenApsExponential – guard conditions

    func testZeroInsulinReturnsZero() {
        XCTAssertEqual(
            InsulinIOB.iobOpenApsExponential(insulinUnits: 0, minsAgo: 30, diaHours: 4, peak: 55), 0)
    }

    func testNegativeInsulinReturnsZero() {
        XCTAssertEqual(
            InsulinIOB.iobOpenApsExponential(insulinUnits: -5, minsAgo: 30, diaHours: 4, peak: 55), 0)
    }

    func testNegativeMinsAgoReturnsZero() {
        XCTAssertEqual(
            InsulinIOB.iobOpenApsExponential(insulinUnits: 1, minsAgo: -1, diaHours: 4, peak: 55), 0)
    }

    func testMinsAgoExactlyAtEndReturnsZero() {
        // end = diaHours * 60 = 240; minsAgo == end is excluded
        XCTAssertEqual(
            InsulinIOB.iobOpenApsExponential(insulinUnits: 1, minsAgo: 240, diaHours: 4, peak: 55), 0)
    }

    func testMinsAgoBeyondEndReturnsZero() {
        XCTAssertEqual(
            InsulinIOB.iobOpenApsExponential(insulinUnits: 1, minsAgo: 300, diaHours: 4, peak: 55), 0)
    }

    // MARK: - iobOpenApsExponential – normal operation

    func testAtTimeZeroIOBEqualsFullDose() {
        // Immediately after injection nothing has been absorbed yet → IOB ≈ full dose
        let iob = InsulinIOB.iobOpenApsExponential(insulinUnits: 5, minsAgo: 0, diaHours: 4, peak: 55)
        XCTAssertEqual(iob, 5, accuracy: 0.01)
    }

    func testIOBDecaysOverTime() {
        let dose = 10.0
        let iob30  = InsulinIOB.iobOpenApsExponential(insulinUnits: dose, minsAgo: 30,  diaHours: 4, peak: 55)
        let iob60  = InsulinIOB.iobOpenApsExponential(insulinUnits: dose, minsAgo: 60,  diaHours: 4, peak: 55)
        let iob120 = InsulinIOB.iobOpenApsExponential(insulinUnits: dose, minsAgo: 120, diaHours: 4, peak: 55)
        XCTAssertGreaterThan(iob30, iob60)
        XCTAssertGreaterThan(iob60, iob120)
    }

    func testIOBNeverExceedsDose() {
        for minsAgo in stride(from: 0.0, to: 240.0, by: 10) {
            let iob = InsulinIOB.iobOpenApsExponential(
                insulinUnits: 8, minsAgo: minsAgo, diaHours: 4, peak: 55)
            XCTAssertLessThanOrEqual(iob, 8, "IOB exceeded dose at t=\(minsAgo)")
        }
    }

    func testIOBAlwaysNonNegative() {
        for minsAgo in stride(from: 0.0, to: 300.0, by: 15) {
            let iob = InsulinIOB.iobOpenApsExponential(
                insulinUnits: 3, minsAgo: minsAgo, diaHours: 4, peak: 55)
            XCTAssertGreaterThanOrEqual(iob, 0, "IOB went negative at t=\(minsAgo)")
        }
    }

    func testAtPeakIOBIsPartiallyAbsorbed() {
        let iob = InsulinIOB.iobOpenApsExponential(insulinUnits: 10, minsAgo: 55, diaHours: 4, peak: 55)
        XCTAssertGreaterThan(iob, 0)
        XCTAssertLessThan(iob, 10)
    }

    func testIOBJustBeforeEndIsNearZero() {
        let iob = InsulinIOB.iobOpenApsExponential(insulinUnits: 10, minsAgo: 239, diaHours: 4, peak: 55)
        XCTAssertGreaterThanOrEqual(iob, 0)
        XCTAssertLessThan(iob, 1.0)   // nearly exhausted
    }

    func testScalesLinearlyWithDose() {
        let iob1 = InsulinIOB.iobOpenApsExponential(insulinUnits: 5,  minsAgo: 60, diaHours: 4, peak: 55)
        let iob2 = InsulinIOB.iobOpenApsExponential(insulinUnits: 10, minsAgo: 60, diaHours: 4, peak: 55)
        XCTAssertEqual(iob2, iob1 * 2, accuracy: 0.001)
    }

    // MARK: - iobOpenApsExponential – denom near-zero fallback

    func testDenomNearZeroUsesLinearFallback() {
        // peak = end/2 → denom = 1 - (2 * peak) / end = 1 - 1 = 0 (near-zero)
        // Linear fallback: insulinUnits * max(0, 1 - minsAgo/end)
        // At minsAgo = 120, end = 240 → expected = 10 * (1 - 0.5) = 5
        let iob = InsulinIOB.iobOpenApsExponential(insulinUnits: 10, minsAgo: 120, diaHours: 4, peak: 120)
        XCTAssertEqual(iob, 5, accuracy: 0.1)
    }

    func testDenomNearZeroAtTimeZeroReturnsDose() {
        let iob = InsulinIOB.iobOpenApsExponential(insulinUnits: 6, minsAgo: 0, diaHours: 4, peak: 120)
        XCTAssertEqual(iob, 6, accuracy: 0.01)
    }

    // MARK: - currentIOBFromNotes

    func testEmptyNotesReturnsZero() {
        XCTAssertEqual(InsulinIOB.currentIOBFromNotes(notes: []), 0)
    }

    func testNoteWithZeroInsulinIgnored() {
        let note = makeNote(insulin: 0, minsAgo: 30)
        XCTAssertEqual(InsulinIOB.currentIOBFromNotes(notes: [note]), 0)
    }

    func testNoteWithNilTimestampIgnored() {
        let note = BackendAPI.GlucoseNote(
            id: "1", timestamp: nil, carbs: 0, insulin: 5, meal: "Lunch",
            comment: nil, glucoseValue: nil, absorptionMode: nil, nutritionProfile: nil, photoUrl: nil)
        XCTAssertEqual(InsulinIOB.currentIOBFromNotes(notes: [note]), 0)
    }

    func testRecentDoseProducesPositiveIOB() {
        let note = makeNote(insulin: 5, minsAgo: 30)
        let iob = InsulinIOB.currentIOBFromNotes(notes: [note])
        XCTAssertGreaterThan(iob, 0)
        XCTAssertLessThanOrEqual(iob, 5)
    }

    func testExpiredDoseProducesZeroIOB() {
        // 5 hours ago > 4 h DIA — fully cleared
        let note = makeNote(insulin: 5, minsAgo: 300)
        XCTAssertEqual(InsulinIOB.currentIOBFromNotes(notes: [note]), 0)
    }

    func testMultipleDosesAreSummed() {
        let note1 = makeNote(insulin: 3, minsAgo: 30)
        let note2 = makeNote(insulin: 4, minsAgo: 60)
        let combined  = InsulinIOB.currentIOBFromNotes(notes: [note1, note2])
        let individual = InsulinIOB.currentIOBFromNotes(notes: [note1])
                       + InsulinIOB.currentIOBFromNotes(notes: [note2])
        XCTAssertEqual(combined, individual, accuracy: 0.0001)
    }

    func testCustomReferenceDate() {
        // Dose given 60 min before our reference point
        let ref   = Date(timeIntervalSinceNow: -3600)
        let doseTs = Date(timeIntervalSince1970: ref.timeIntervalSince1970 - 3600)
        let note = BackendAPI.GlucoseNote(
            id: "x", timestamp: doseTs, carbs: 0, insulin: 8, meal: "Correction",
            comment: nil, glucoseValue: nil, absorptionMode: nil, nutritionProfile: nil, photoUrl: nil)
        let iob = InsulinIOB.currentIOBFromNotes(notes: [note], at: ref)
        XCTAssertGreaterThan(iob, 0)
        XCTAssertLessThanOrEqual(iob, 8)
    }

    func testResultIsAlwaysNonNegative() {
        // Simulate mix of old and fresh doses
        let notes = [makeNote(insulin: 2, minsAgo: 280),
                     makeNote(insulin: 0, minsAgo: 10)]
        let iob = InsulinIOB.currentIOBFromNotes(notes: notes)
        XCTAssertGreaterThanOrEqual(iob, 0)
    }

    // MARK: - Long-acting (basal) exclusion

    func testLongActingNoteExcludedFromIOB() {
        // A long-acting (basal) dose must contribute ZERO rapid-acting IOB, even recent and large.
        let basal = BackendAPI.GlucoseNote(
            id: "basal", timestamp: Date(timeIntervalSinceNow: -30 * 60),
            carbs: 0, insulin: 20, meal: "Tresiba",
            comment: nil, glucoseValue: nil, absorptionMode: nil, nutritionProfile: nil,
            type: BackendAPI.NoteType.longActing, photoUrl: nil)
        XCTAssertEqual(InsulinIOB.currentIOBFromNotes(notes: [basal]), 0, accuracy: 1e-9)
    }

    func testLongActingDoesNotAffectBolusSum() {
        // A bolus plus a long-acting note → IOB equals the bolus alone (basal ignored).
        let bolus = makeNote(insulin: 4, minsAgo: 30)
        let basal = BackendAPI.GlucoseNote(
            id: "basal", timestamp: Date(timeIntervalSinceNow: -30 * 60),
            carbs: 0, insulin: 20, meal: "Tresiba",
            comment: nil, glucoseValue: nil, absorptionMode: nil, nutritionProfile: nil,
            type: BackendAPI.NoteType.longActing, photoUrl: nil)
        // Use one reference instant so both calls sample the bolus curve at the same time.
        let now = Date()
        let withBasal = InsulinIOB.currentIOBFromNotes(notes: [bolus, basal], at: now)
        let bolusOnly = InsulinIOB.currentIOBFromNotes(notes: [bolus], at: now)
        XCTAssertEqual(withBasal, bolusOnly, accuracy: 1e-9)
    }

    // MARK: - Helpers

    private func makeNote(insulin: Double, minsAgo: Double) -> BackendAPI.GlucoseNote {
        BackendAPI.GlucoseNote(
            id: UUID().uuidString,
            timestamp: Date(timeIntervalSinceNow: -minsAgo * 60),
            carbs: 0, insulin: insulin, meal: "Correction",
            comment: nil, glucoseValue: nil, absorptionMode: nil, nutritionProfile: nil, photoUrl: nil)
    }
}
