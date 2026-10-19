import XCTest
@testable import GlucoseMonitor

final class InjectionSiteRulesTests: XCTestCase {

    private func recent(_ id: String, _ zone: String, minutesAgo: Double) -> BackendAPI.InjectionSites.Recent {
        BackendAPI.InjectionSites.Recent(noteId: id, time: Date(timeIntervalSinceNow: -minutesAgo * 60),
                                         zone: zone, units: 2, basal: false)
    }

    func testPickingTheSameZoneAThirdTimeInARowWarns() {
        let history = [recent("a", "abd_ur", minutesAgo: 60), recent("b", "abd_ur", minutesAgo: 300)]
        XCTAssertTrue(InjectionSiteRules.wouldRepeat("abd_ur", recent: history, excluding: "new"))
        XCTAssertFalse(InjectionSiteRules.wouldRepeat("abd_ul", recent: history, excluding: "new"))
    }

    func testDontRememberAnswersAreSkipped() {
        let history = [recent("a", "abd_ur", minutesAgo: 60), recent("u", "unknown", minutesAgo: 120),
                       recent("b", "abd_ur", minutesAgo: 300)]
        XCTAssertTrue(InjectionSiteRules.wouldRepeat("abd_ur", recent: history, excluding: "new"))
    }

    func testTheDoseBeingAnsweredDoesNotCountAgainstItself() {
        // Re-answering dose "a" (already stored as abd_ur): only "b" precedes it, so no run of three.
        let history = [recent("a", "abd_ur", minutesAgo: 60), recent("b", "abd_ur", minutesAgo: 300)]
        XCTAssertFalse(InjectionSiteRules.wouldRepeat("abd_ur", recent: history, excluding: "a"))
    }

    func testNoWarningWithTooLittleHistory() {
        XCTAssertFalse(InjectionSiteRules.wouldRepeat("abd_ur", recent: [recent("a", "abd_ur", minutesAgo: 60)], excluding: "new"))
    }

    func testZoneLabels() {
        XCTAssertEqual(InjectionZone.label(for: "flank_l"), "Flank, left")
        XCTAssertEqual(InjectionZone.label(for: "unknown"), "Not remembered")
        XCTAssertNil(InjectionZone.label(for: "left_ear"))
        XCTAssertEqual(InjectionZone.all.count, 12)
        XCTAssertEqual(Set(InjectionZone.all.map(\.code)).count, 12)
    }

    func testSiteZoneDecodesOnNotes() throws {
        let json = #"{"id":"n1","timestamp":"2026-10-19T12:00:00","carbs":0,"insulin":2,"meal":"Correction","photoUrl":null,"siteZone":"abd_ul"}"#
        let note = try GlucoseMonitorAPI.jsonDecoder().decode(BackendAPI.GlucoseNote.self, from: Data(json.utf8))
        XCTAssertEqual(note.siteZone, "abd_ul")
    }
}
