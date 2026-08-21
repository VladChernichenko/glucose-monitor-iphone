import XCTest
@testable import GlucoseMonitor

final class HypoPromptTests: XCTestCase {

    /// The backend speaks mmol/L only. A mg/dL user must see 63, not 3.5.
    func testTriggerGlucoseConvertsForMgdlDisplay() {
        let mmol = 3.5
        let displayed = GlucoseUnit.fromMmol(mmol, displayUnit: "mg/dL")
        XCTAssertEqual(displayed, 63.06, accuracy: 0.1)
    }

    func testTriggerGlucoseStaysUnchangedForMmolDisplay() {
        let displayed = GlucoseUnit.fromMmol(3.5, displayUnit: "mmol/L")
        XCTAssertEqual(displayed, 3.5, accuracy: 0.001)
    }

    func testPresetsAreTenFifteenTwenty() {
        XCTAssertEqual(BackendAPI.RescueCarbPresets.options, [10, 15, 20])
    }
}
