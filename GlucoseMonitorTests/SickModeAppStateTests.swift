import XCTest
@testable import GlucoseMonitor

@MainActor
final class SickModeAppStateTests: XCTestCase {

    private let noteId = UUID(uuidString: "7B1E5A52-3C11-4E4B-8F0A-0A8C5C1D2E3F")!

    private func statusJSON(severity: String, stepUp: Bool = false) -> Data {
        let step = stepUp ? "{\"noteId\":\"\(noteId.uuidString)\",\"toSeverity\":\"SEVERE_UNRESPONSIVE\",\"showHelpLine\":true}" : "null"
        return Data("""
        {"active":true,"severity":"\(severity)","since":"2026-11-15T07:30:00","dayNumber":1,"isfPercent":-15,
         "basalNeedPercent":0,"confirmationDue":false,"stepUp":\(step)}
        """.utf8)
    }

    override func setUp() {
        super.setUp()
        StubURLProtocol.reset()
        URLProtocol.registerClass(StubURLProtocol.self)
    }

    private func makeState() -> AppState {
        GlucoseMonitorAPI.storeSessionTokens(accessToken: "test-token", refreshToken: nil)
        let s = AppState()
        // The post-command dashboard refresh is a no-op while signed out of the UI, so these tests
        // exercise only the command and state handling (the stub has no dashboard endpoints).
        s.isAuthenticated = false
        return s
    }

    override func tearDown() {
        URLProtocol.unregisterClass(StubURLProtocol.self)
        StubURLProtocol.reset()
        GlucoseMonitorAPI.clearSession()
        super.tearDown()
    }

    func testCommandResultReplacesTheCachedStatus() async {
        StubURLProtocol.enqueue(path: "/api/sick-mode/start", .init(status: 200, body: statusJSON(severity: "MILD")))
        StubURLProtocol.enqueue(path: "/api/sick-mode/severity", .init(status: 200, body: statusJSON(severity: "SEVERE")))
        let s = makeState()
        await s.startSickMode(.mild, since: .thisMorning)
        XCTAssertEqual(s.sickMode?.severity, .mild)
        await s.changeSickSeverity(.severe)
        XCTAssertEqual(s.sickMode?.severity, .severe)
        XCTAssertNil(s.errorMessage)
    }

    func testFailedCommandKeepsTheStatusAndReportsTheError() async {
        StubURLProtocol.enqueue(path: "/api/sick-mode/start", .init(status: 200, body: statusJSON(severity: "MILD")))
        StubURLProtocol.enqueue(path: "/api/sick-mode/severity", .jsonError(status: 400, message: "rejected"))
        let s = makeState()
        await s.startSickMode(.mild, since: .now)
        await s.changeSickSeverity(.severe)
        XCTAssertEqual(s.sickMode?.severity, .mild)
        XCTAssertNotNil(s.errorMessage)
    }

    func testStepUpUsesTheNoteIdFromTheCurrentStatus() async throws {
        StubURLProtocol.enqueue(path: "/api/sick-mode/start", .init(status: 200, body: statusJSON(severity: "SEVERE", stepUp: true)))
        StubURLProtocol.enqueue(path: "/api/sick-mode/step-up", .init(status: 200, body: statusJSON(severity: "SEVERE_UNRESPONSIVE")))
        let s = makeState()
        await s.startSickMode(.severe, since: .now)
        XCTAssertEqual(s.sickMode?.stepUp?.noteId, noteId)
        await s.decideSickStepUp(accept: true)
        XCTAssertEqual(StubURLProtocol.hits(for: "/api/sick-mode/step-up"), 1)
        XCTAssertEqual(s.sickMode?.severity, .severeUnresponsive)
        XCTAssertNil(s.sickMode?.stepUp)
    }

    func testStepUpWithNothingPendingDoesNothing() async {
        let s = AppState()
        await s.decideSickStepUp(accept: true)
        XCTAssertEqual(StubURLProtocol.hits(for: "/api/sick-mode/step-up"), 0)
    }

    func testNewCalculationsReplaceTheStatus() async throws {
        let s = AppState()
        s.sickMode = SickModeStatus(active: true, severity: .mild)
        s.calculations = BackendAPI.decodeGlucoseCalculationsResponse(from: Data(
            #"{"data":{"activeCarbsOnBoard":0,"activeInsulinOnBoard":0,"twoHourPrediction":6,"predictionTrend":"stable","confidence":0.5}}"#.utf8))
        XCTAssertNil(s.sickMode, "no sickMode in the newest calculations means sick mode is off")
    }
}
