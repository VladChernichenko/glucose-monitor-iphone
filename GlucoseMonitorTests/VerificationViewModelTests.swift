import XCTest
@testable import GlucoseMonitor

@MainActor
final class VerificationViewModelTests: XCTestCase {

    // T11 - VerificationSummary decodes correctly from backend JSON
    func test_verificationSummary_decodes_nEvents_and_suggestionReady() {
        let json = """
        {
          "nEvents": 7,
          "meanError": 0.62,
          "consistencyScore": 0.78,
          "suggestedCarbRatio": 0.26,
          "suggestionReady": true,
          "confidence": "HIGH",
          "lastUpdated": "2026-06-04T12:00:00"
        }
        """
        let decoder = JSONDecoder(); decoder.keyDecodingStrategy = .convertFromSnakeCase
        let summary = try! decoder.decode(VerificationSummary.self, from: json.data(using: .utf8)!)
        XCTAssertEqual(summary.nEvents, 7)
        XCTAssertTrue(summary.suggestionReady)
        XCTAssertEqual(summary.confidence, "HIGH")
        XCTAssertEqual(summary.suggestedCarbRatio!, 0.26, accuracy: 0.001)
        XCTAssertEqual(summary.meanError!, 0.62, accuracy: 0.001)
    }

    // T12 - VerificationSummary with low confidence and no suggestion
    func test_verificationSummary_noSuggestion_whenLowConfidence() {
        let json = """
        {"nEvents":3,"meanError":0.4,"consistencyScore":0.3,"suggestionReady":false,"confidence":"LOW"}
        """
        let decoder = JSONDecoder(); decoder.keyDecodingStrategy = .convertFromSnakeCase
        let summary = try! decoder.decode(VerificationSummary.self, from: json.data(using: .utf8)!)
        XCTAssertFalse(summary.suggestionReady)
        XCTAssertEqual(summary.confidence, "LOW")
        XCTAssertNil(summary.suggestedCarbRatio)
        XCTAssertNil(summary.suggestedIsf)
    }

    // T13 - VerificationEventModel decodes status and deltas
    func test_verificationEvent_decodes_predictedAndActualDelta() {
        let json = """
        {
          "id": "00000000-0000-0000-0000-000000000001",
          "noteId": "00000000-0000-0000-0000-000000000002",
          "status": "COMPLETED",
          "baselineGlucose": 7.2,
          "actualGlucose2h": 9.8,
          "predictedDelta": 2.1,
          "actualDelta": 2.6,
          "error": 0.5,
          "relativeErrorPct": 23.8,
          "createdAt": "2026-06-03T08:00:00"
        }
        """
        let decoder = JSONDecoder(); decoder.keyDecodingStrategy = .convertFromSnakeCase
        let event = try! decoder.decode(VerificationEventModel.self, from: json.data(using: .utf8)!)
        XCTAssertEqual(event.status, "COMPLETED")
        XCTAssertEqual(event.predictedDelta!, 2.1, accuracy: 0.01)
        XCTAssertEqual(event.actualDelta!, 2.6, accuracy: 0.01)
        XCTAssertEqual(event.error!, 0.5, accuracy: 0.01)
    }

    // T14 - VerificationSummary.confidenceColor matches expected values
    func test_confidenceColor_mapsCorrectly() {
        let decoder = JSONDecoder(); decoder.keyDecodingStrategy = .convertFromSnakeCase

        let highJSON = "{\"nEvents\":7,\"suggestionReady\":true,\"confidence\":\"HIGH\"}"
        let high = try! decoder.decode(VerificationSummary.self, from: highJSON.data(using: .utf8)!)
        XCTAssertEqual(high.confidenceColor, "green")

        let medJSON = "{\"nEvents\":5,\"suggestionReady\":false,\"confidence\":\"MEDIUM\"}"
        let med = try! decoder.decode(VerificationSummary.self, from: medJSON.data(using: .utf8)!)
        XCTAssertEqual(med.confidenceColor, "yellow")

        let lowJSON = "{\"nEvents\":2,\"suggestionReady\":false,\"confidence\":\"LOW\"}"
        let low = try! decoder.decode(VerificationSummary.self, from: lowJSON.data(using: .utf8)!)
        XCTAssertEqual(low.confidenceColor, "red")
    }

    // T15 - VerificationViewModel.completedEvents filters correctly
    func test_completedEvents_filtersOnlyCompleted() {
        let vm = VerificationViewModel()
        let decoder = JSONDecoder(); decoder.keyDecodingStrategy = .convertFromSnakeCase

        let json = """
        [
          {"status":"COMPLETED","predictedDelta":2.1,"actualDelta":2.6},
          {"status":"SKIPPED","skipReason":"no_insulin"},
          {"status":"PENDING"}
        ]
        """
        vm.events = try! decoder.decode([VerificationEventModel].self, from: json.data(using: .utf8)!)
        XCTAssertEqual(vm.completedEvents.count, 1,
                "Only COMPLETED events should appear in completedEvents")
        XCTAssertEqual(vm.completedEvents.first?.status, "COMPLETED")
    }
}
