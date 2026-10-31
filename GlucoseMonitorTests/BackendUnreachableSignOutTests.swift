import XCTest
@testable import GlucoseMonitor

final class BackendUnreachableSignOutTests: XCTestCase {

    override func tearDown() {
        GlucoseMonitorAPI.sharedDefaults().removeObject(forKey: BackendAPI.signOutReasonKey)
        super.tearDown()
    }

    func testTransportFailuresCountAsUnreachable() {
        for code: URLError.Code in [.cannotConnectToHost, .cannotFindHost, .dnsLookupFailed, .timedOut,
                                    .networkConnectionLost, .notConnectedToInternet] {
            XCTAssertTrue(BackendAPI.isBackendUnreachable(URLError(code)), "\(code)")
        }
    }

    func testAnswersFromTheServerAndCancellationDoNot() {
        XCTAssertFalse(BackendAPI.isBackendUnreachable(URLError(.cancelled)))
        XCTAssertFalse(BackendAPI.isBackendUnreachable(URLError(.badServerResponse)))
        XCTAssertFalse(BackendAPI.isBackendUnreachable(GlucoseMonitorAPI.APIError.httpStatus(503, nil)))
        XCTAssertFalse(BackendAPI.isBackendUnreachable(CancellationError()))
    }

    func testAnUnreachableBackendSignsOutAndRecordsWhy() async {
        let cleared = expectation(forNotification: GlucoseMonitorAPI.sessionClearedNotification, object: nil)

        do {
            _ = try await BackendAPI.performWithRefresh { () async throws -> Int in throw URLError(.cannotConnectToHost) }
            XCTFail("the error must still reach the caller")
        } catch {
            XCTAssertEqual((error as? URLError)?.code, .cannotConnectToHost)
        }

        await fulfillment(of: [cleared], timeout: 1)
        XCTAssertEqual(GlucoseMonitorAPI.sharedDefaults().string(forKey: BackendAPI.signOutReasonKey),
                       BackendAPI.backendUnreachableReason)
    }

    func testAServerErrorDoesNotSignOut() async {
        let cleared = expectation(forNotification: GlucoseMonitorAPI.sessionClearedNotification, object: nil)
        cleared.isInverted = true

        _ = try? await BackendAPI.performWithRefresh { () async throws -> Int in
            throw GlucoseMonitorAPI.APIError.httpStatus(500, nil)
        }

        await fulfillment(of: [cleared], timeout: 0.3)
        XCTAssertNil(GlucoseMonitorAPI.sharedDefaults().string(forKey: BackendAPI.signOutReasonKey))
    }
}
