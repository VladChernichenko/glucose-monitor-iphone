import XCTest
@testable import GlucoseMonitor

final class SickModeTextTests: XCTestCase {

    func testTitleAndDetailForModerateDayTwo() {
        let s = SickModeStatus(active: true, severity: .moderate, dayNumber: 2, isfPercent: -30, basalNeedPercent: 15)
        XCTAssertEqual(SickModeText.title(s), "Sick · moderate · day 2")
        XCTAssertEqual(SickModeText.detail(s), "ISF −30% · basal need +15%")
    }

    func testMildDetailShowsZeroBasalAndUnresponsiveHasItsOwnName() {
        let mild = SickModeStatus(active: true, severity: .mild, dayNumber: 1, isfPercent: -15, basalNeedPercent: 0)
        XCTAssertEqual(SickModeText.detail(mild), "ISF −15% · basal need +0%")
        let worst = SickModeStatus(active: true, severity: .severeUnresponsive, dayNumber: 3, isfPercent: -60, basalNeedPercent: 30)
        XCTAssertEqual(SickModeText.title(worst), "Sick · severe, not responding · day 3")
    }

    func testUnresponsiveLevelIsNotInThePicker() {
        XCTAssertEqual(SickModeText.pickerLevels, [.mild, .moderate, .severe])
        XCTAssertFalse(SickModeText.pickerLevels.contains(.severeUnresponsive))
        XCTAssertTrue(SickModeText.symptoms(.moderate).contains("37.5–38.5"))
        XCTAssertTrue(SickModeText.symptoms(.mild).contains("ISF −15%, basal need +0%"))
        XCTAssertTrue(SickModeText.symptoms(.severe).contains("ISF −50%, basal need +30%"))
    }

    func testStepUpQuestionNamesTheTargetLevel() {
        XCTAssertEqual(SickModeText.stepUpQuestion(.severe), "Treat this as severe illness? (ISF −50%)")
        XCTAssertEqual(SickModeText.stepUpQuestion(.moderate), "Treat this as moderate illness? (ISF −30%)")
        XCTAssertEqual(SickModeText.stepUpQuestion(.severeUnresponsive),
                       "Treat this as severe illness, not responding? (ISF −60%)")
        XCTAssertEqual(SickModeText.stepUpQuestion(nil), "")
    }

    func testKeepButtonNamesTheCurrentLevel() {
        XCTAssertEqual(SickModeText.keepTitle(.moderate), "Keep moderate")
        XCTAssertEqual(SickModeText.keepTitle(nil), "Keep current")
    }

    func testChangePickerOpensOnTheCurrentLevelAndMapsTheTopLevelToSevere() {
        XCTAssertEqual(SickSeverityPicker.initialSelection(mode: .change, current: .mild), .mild)
        XCTAssertEqual(SickSeverityPicker.initialSelection(mode: .change, current: .moderate), .moderate)
        XCTAssertEqual(SickSeverityPicker.initialSelection(mode: .change, current: .severe), .severe)
        XCTAssertEqual(SickSeverityPicker.initialSelection(mode: .change, current: .severeUnresponsive), .severe)
    }

    func testStartPickerOpensOnMild() {
        XCTAssertEqual(SickSeverityPicker.initialSelection(mode: .start, current: nil), .mild)
    }

    func testChangeSaveIsOffWhileTheSelectionIsTheCurrentOrMappedLevel() {
        XCTAssertFalse(SickSeverityPicker.canSave(mode: .change, current: .moderate, selection: .moderate))
        XCTAssertTrue(SickSeverityPicker.canSave(mode: .change, current: .moderate, selection: .severe))
        XCTAssertFalse(SickSeverityPicker.canSave(mode: .change, current: .severeUnresponsive, selection: .severe))
        XCTAssertTrue(SickSeverityPicker.canSave(mode: .change, current: .severeUnresponsive, selection: .mild))
        XCTAssertTrue(SickSeverityPicker.canSave(mode: .start, current: nil, selection: .mild))
    }
}
