import XCTest
@testable import GlucoseMonitor

/// The app signs the user out only when the backend rejects the refresh token. Being unable to
/// reach the backend, or a server error, must leave the session intact.
final class SessionSignOutPolicyTests: XCTestCase {

    private let unauthorized = GlucoseMonitorAPI.APIError.httpStatus(401, nil)

    override func tearDown() {
        GlucoseMonitorAPI.sharedDefaults().removeObject(forKey: BackendAPI.signOutReasonKey)
        super.tearDown()
    }

    func testOnlyARejectedRefreshTokenEndsTheSession() {
        XCTAssertTrue(BackendAPI.isSessionRejected(GlucoseMonitorAPI.APIError.httpStatus(401, nil)))
        XCTAssertTrue(BackendAPI.isSessionRejected(GlucoseMonitorAPI.APIError.missingToken))

        XCTAssertFalse(BackendAPI.isSessionRejected(GlucoseMonitorAPI.APIError.httpStatus(500, nil)))
        XCTAssertFalse(BackendAPI.isSessionRejected(GlucoseMonitorAPI.APIError.httpStatus(503, nil)))
        XCTAssertFalse(BackendAPI.isSessionRejected(GlucoseMonitorAPI.APIError.httpStatus(429, nil)))
        for code: URLError.Code in [.cannotConnectToHost, .cannotFindHost, .dnsLookupFailed, .timedOut,
                                    .networkConnectionLost, .notConnectedToInternet] {
            XCTAssertFalse(BackendAPI.isSessionRejected(URLError(code)), "\(code)")
        }
        XCTAssertFalse(BackendAPI.isSessionRejected(CancellationError()))
    }

    func testAnUnreachableBackendKeepsTheUserSignedIn() async {
        let cleared = sessionClearedExpectation(inverted: true)

        do {
            _ = try await BackendAPI.performWithRefresh { () async throws -> Int in throw URLError(.cannotConnectToHost) }
            XCTFail("the error must still reach the caller")
        } catch {
            XCTAssertEqual((error as? URLError)?.code, .cannotConnectToHost)
        }

        await fulfillment(of: [cleared], timeout: 0.3)
        XCTAssertNil(GlucoseMonitorAPI.sharedDefaults().string(forKey: BackendAPI.signOutReasonKey))
    }

    func testAServerErrorDoesNotSignOut() async {
        let cleared = sessionClearedExpectation(inverted: true)

        _ = try? await BackendAPI.performWithRefresh { () async throws -> Int in
            throw GlucoseMonitorAPI.APIError.httpStatus(500, nil)
        }

        await fulfillment(of: [cleared], timeout: 0.3)
        XCTAssertNil(GlucoseMonitorAPI.sharedDefaults().string(forKey: BackendAPI.signOutReasonKey))
    }

    func testRefreshThatCannotReachTheBackendKeepsTheUserSignedIn() async {
        let cleared = sessionClearedExpectation(inverted: true)

        do {
            _ = try await BackendAPI.performWithRefresh(
                refresh: { throw URLError(.notConnectedToInternet) },
                { () async throws -> Int in throw self.unauthorized })
            XCTFail("the error must still reach the caller")
        } catch {
            XCTAssertEqual((error as? URLError)?.code, .notConnectedToInternet,
                           "the caller should see why the refresh did not go through")
        }

        await fulfillment(of: [cleared], timeout: 0.3)
        XCTAssertNil(GlucoseMonitorAPI.sharedDefaults().string(forKey: BackendAPI.signOutReasonKey))
    }

    func testRefreshAnsweredWithServerErrorKeepsTheUserSignedIn() async {
        let cleared = sessionClearedExpectation(inverted: true)

        _ = try? await BackendAPI.performWithRefresh(
            refresh: { throw GlucoseMonitorAPI.APIError.httpStatus(503, nil) },
            { () async throws -> Int in throw self.unauthorized })

        await fulfillment(of: [cleared], timeout: 0.3)
    }

    func testRefreshRejectedByTheBackendSignsOutAndRecordsWhy() async {
        let cleared = sessionClearedExpectation(inverted: false)

        _ = try? await BackendAPI.performWithRefresh(
            refresh: { throw GlucoseMonitorAPI.APIError.httpStatus(401, nil) },
            { () async throws -> Int in throw self.unauthorized })

        await fulfillment(of: [cleared], timeout: 1)
        XCTAssertEqual(GlucoseMonitorAPI.sharedDefaults().string(forKey: BackendAPI.signOutReasonKey),
                       BackendAPI.sessionEndedReason)
    }

    func testSuccessfulRefreshRetriesTheCall() async throws {
        var attempts = 0
        let value = try await BackendAPI.performWithRefresh(
            refresh: {},
            { () async throws -> Int in
                attempts += 1
                if attempts == 1 { throw self.unauthorized }
                return 7
            })

        XCTAssertEqual(value, 7)
        XCTAssertEqual(attempts, 2)
    }

    private func sessionClearedExpectation(inverted: Bool) -> XCTestExpectation {
        let cleared = expectation(forNotification: GlucoseMonitorAPI.sessionClearedNotification, object: nil)
        cleared.isInverted = inverted
        return cleared
    }
}
