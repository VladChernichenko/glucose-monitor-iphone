import XCTest
@testable import GlucoseMonitor

/// Unit tests for `LongActingSchedule` - the hint on the dashboard "Long-acting insulin" action.
/// Pyramid layer: Unit (base).
///
/// Regression context: the action was greyed out (not tappable) outside 1 h before to 4 h after the
/// configured injection time, so a dose taken early, late or off-schedule could not be logged.
/// The schedule now only produces a label; `Status` carries no enabled flag to gate the button on.
final class LongActingScheduleTests: XCTestCase {

    private var calendar: Calendar {
        var c = Calendar(identifier: .gregorian)
        c.timeZone = TimeZone(identifier: "UTC")!
        return c
    }

    private func at(_ hour: Int, _ minute: Int = 0) -> Date {
        calendar.date(from: DateComponents(year: 2026, month: 11, day: 26, hour: hour, minute: minute))!
    }

    func testNoScheduleGivesEmptyLabel() {
        XCTAssertEqual(LongActingSchedule.status(injectionTimeHHmm: nil, now: at(12), calendar: calendar).label, "")
        XCTAssertEqual(LongActingSchedule.status(injectionTimeHHmm: "", now: at(12), calendar: calendar).label, "")
    }

    func testBeforeScheduledTimeIsDue() {
        let s = LongActingSchedule.status(injectionTimeHHmm: "22:00", now: at(21, 30), calendar: calendar)
        XCTAssertEqual(s.label, "Due 22:00")
    }

    func testShortlyAfterScheduledTimeIsLogNow() {
        let s = LongActingSchedule.status(injectionTimeHHmm: "22:00", now: at(23), calendar: calendar)
        XCTAssertEqual(s.label, "Log now")
    }

    func testWindowWorksAcrossMidnight() {
        let s = LongActingSchedule.status(injectionTimeHHmm: "22:00", now: at(1), calendar: calendar)
        XCTAssertEqual(s.label, "Log now")
    }

    /// Outside the window the row still shows when the next dose is due - but only as a hint.
    func testOutsideWindowShowsNextTimeHint() {
        let s = LongActingSchedule.status(injectionTimeHHmm: "22:00", now: at(12), calendar: calendar)
        XCTAssertEqual(s, LongActingSchedule.Status(label: "Next at 22:00"))
    }
}
