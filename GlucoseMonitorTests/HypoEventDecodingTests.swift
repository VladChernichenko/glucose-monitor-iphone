import XCTest
@testable import GlucoseMonitor

/// Pins the two JSON shapes the backend actually sends for `BackendAPI.HypoEvent`:
/// an OPEN event, where `noteId` and `resolvedAt` are `null` (this is the only state
/// the app polls for, and the state a patient sees during a real hypo), and a
/// CONFIRMED event, where both are populated.
///
/// Decodes with `GlucoseMonitorAPI.jsonDecoder()` - the exact decoder
/// `BackendAPI.fetchOpenHypoEvents()` uses - so a failure here means the real
/// network path would fail too, not just some stand-in `JSONDecoder()`.
final class HypoEventDecodingTests: XCTestCase {

    func testDecodesOpenEvent_withNullNoteIdAndResolvedAt() throws {
        let json = """
        {"id":"3f2a1b4c-5d6e-7f80-9a1b-2c3d4e5f6071","triggerGlucoseMmol":3.4,"state":"OPEN",
         "noteId":null,"detectedAt":"2026-08-21T09:15:00","resolvedAt":null}
        """.data(using: .utf8)!

        let event = try GlucoseMonitorAPI.jsonDecoder().decode(BackendAPI.HypoEvent.self, from: json)

        XCTAssertEqual(event.id, "3f2a1b4c-5d6e-7f80-9a1b-2c3d4e5f6071")
        XCTAssertEqual(event.triggerGlucoseMmol, 3.4)
        XCTAssertEqual(event.state, "OPEN")
        XCTAssertNil(event.noteId, "OPEN events have no note yet - noteId must decode as nil, not throw.")
        XCTAssertEqual(event.detectedAt, "2026-08-21T09:15:00")
        XCTAssertNil(event.resolvedAt, "OPEN events are unresolved - resolvedAt must decode as nil.")
    }

    func testDecodesConfirmedEvent_withNoteIdAndResolvedAtPopulated() throws {
        let json = """
        {"id":"9c8b7a6d-5e4f-3210-a1b2-c3d4e5f60718","triggerGlucoseMmol":3.6,"state":"CONFIRMED",
         "noteId":"note-123","detectedAt":"2026-08-21T09:15:00","resolvedAt":"2026-08-21T09:20:00"}
        """.data(using: .utf8)!

        let event = try GlucoseMonitorAPI.jsonDecoder().decode(BackendAPI.HypoEvent.self, from: json)

        XCTAssertEqual(event.id, "9c8b7a6d-5e4f-3210-a1b2-c3d4e5f60718")
        XCTAssertEqual(event.triggerGlucoseMmol, 3.6)
        XCTAssertEqual(event.state, "CONFIRMED")
        XCTAssertEqual(event.noteId, "note-123")
        XCTAssertEqual(event.detectedAt, "2026-08-21T09:15:00")
        XCTAssertEqual(event.resolvedAt, "2026-08-21T09:20:00")
    }
}
