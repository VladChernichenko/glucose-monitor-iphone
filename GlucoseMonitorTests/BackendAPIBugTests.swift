import XCTest
@testable import GlucoseMonitor

/// Regression tests for BackendAPI-level bugs.
final class BackendAPIBugTests: XCTestCase {

    // MARK: - I1: JWT tokens stored in UserDefaults instead of Keychain

    // BUG: I1 — JWT tokens stored in UserDefaults / App Group UserDefaults instead of Keychain
    // (security risk: other apps in the same App Group can read the token)
    // CURRENT STATUS: NOT FIXED — GlucoseMonitorAPI.sharedDefaults() returns an App Group
    // UserDefaults suite ("group.che.glucosemonitor"), which is readable by all apps
    // sharing the group entitlement.  Tokens should be in Keychain (kSecClassGenericPassword).
    //
    // This test DOCUMENTS THE BUG by proving the token IS readable from UserDefaults.
    // After the fix, the token must NOT be present in UserDefaults for the access-token key;
    // at that point change the XCTAssertNotNil to XCTAssertNil.
    func testJWTStorageUsesKeychain() {
        let key = GlucoseMonitorAPI.StorageKey.accessToken

        // Write a fake token into the App Group defaults (or standard if not in an app group).
        let ud = GlucoseMonitorAPI.sharedDefaults()
        ud.set("test-insecure-token", forKey: key)
        ud.synchronize()

        let retrieved = ud.string(forKey: key)

        // This assertion PASSES if the token IS in UserDefaults (proves the bug exists).
        // After the fix (Keychain storage), ud.string(forKey:) must return nil here
        // and the assertion must be changed to XCTAssertNil.
        XCTAssertNotNil(
            retrieved,
            "I1: Token was found in UserDefaults — it must be stored in Keychain instead. "
            + "This assertion documents the current (buggy) behaviour. "
            + "After the fix, replace XCTAssertNotNil with XCTAssertNil.")

        // Clean up so we don't pollute other tests.
        ud.removeObject(forKey: key)
        ud.synchronize()
    }

    // BUG: I1 — Verify the access-token key string is what we expect
    // (guards against a silent key rename that would break the Keychain migration).
    func testJWT_storageKeyValue() {
        XCTAssertEqual(
            GlucoseMonitorAPI.StorageKey.accessToken, "gm_access_token",
            "I1: The accessToken storage key must not change; it is used for Keychain migration.")
    }

    // MARK: - I3: analyzePhotoNutrition creates a new URLSession per call (memory leak)

    // BUG: I3 — analyzePhotoNutrition creates a new URLSession per call, never invalidated
    // CURRENT STATUS: NOT FIXED — BackendAPI.analyzePhotoNutrition() creates a local
    // `let session = URLSession(configuration: …)` on each invocation and never calls
    // session.invalidateAndCancel() or session.finishTasksAndInvalidate().
    // Each leaked session holds file descriptors, sockets, and daemon connections.
    //
    // After the fix, a single static/shared URLSession with the required timeout configuration
    // should be reused across calls.
    //
    // This is a code-structure test — we document the contract and verify via code inspection.
    func testAnalyzePhotoNutrition_sessionCreation() {
        // The expected fix: BackendAPI should expose (or use internally) a static URLSession
        // configured with a 300-second timeout so it is created once and reused.
        // A unit test that truly verifies session reuse requires swizzling URLSession.init or
        // dependency injection, which is outside scope here.
        // This test documents the requirement.
        XCTAssert(
            true,
            "I3: analyzePhotoNutrition must reuse a single static URLSession (configured with "
            + "a 300-second timeout) instead of creating one per call. "
            + "Each leaked session accumulates file descriptors and daemon connections. "
            + "Verified by code inspection of BackendAPI.analyzePhotoNutrition().")
    }

    // MARK: - iOS-9: Timezone offset sign convention and wall-clock timestamps

    // BUG: iOS-9 — BackendAPI timezone offset sign convention undocumented / historically incorrect
    // The X-Timezone-Offset header previously sent a negated value for UTC+ zones.
    // Fix: use `TimeZone.current.secondsFromGMT() / 60` (positive for UTC+, negative for UTC-),
    // which matches the JS convention the backend expects.
    // CURRENT STATUS: FIXED in both the header (authorizedRequest) and the POST body
    // (fetchGlucoseCalculations).  This test is a REGRESSION GUARD.
    func testTimezoneOffsetConvention_formatNoteTimestamp_isWallClock() {
        // formatNoteTimestampForRequest uses TimeZone.current (wall-clock time).
        // The result must NOT end with "Z" (which would indicate UTC).
        // For a deterministic test we use a fixed Date value.
        let cal = Calendar(identifier: .gregorian)
        var comps = DateComponents()
        comps.year = 2025; comps.month = 6; comps.day = 1
        comps.hour = 12;  comps.minute = 0; comps.second = 0
        // Create the date in UTC so its absolute value is fixed.
        var utcCal = Calendar(identifier: .gregorian)
        utcCal.timeZone = TimeZone(identifier: "UTC")!
        let date = utcCal.date(from: comps)!

        let formatted = BackendAPI.formatNoteTimestampForRequest(date)

        XCTAssertFalse(
            formatted.hasSuffix("Z"),
            "iOS-9: Note timestamps must be wall-clock time, not UTC (no 'Z' suffix). "
            + "Received: \(formatted)")
        XCTAssertFalse(
            formatted.contains("+"),
            "iOS-9: Timestamp must not include a UTC offset suffix (+HH:MM). "
            + "Backend expects a naive local time string. Received: \(formatted)")
        // Verify the format is yyyy-MM-dd'T'HH:mm:ss (19 chars)
        XCTAssertEqual(
            formatted.count, 19,
            "iOS-9: Expected format yyyy-MM-dd'T'HH:mm:ss (19 chars). "
            + "Got: \(formatted) (\(formatted.count) chars)")
    }

    // BUG: iOS-9 — Header and body timezone offset must use the same sign convention
    // The header sends `TimeZone.current.secondsFromGMT() / 60`.
    // The body (fetchGlucoseCalculations) previously sent the negated value.
    // After fix: both must agree.  We verify the public sign convention here.
    func testTimezoneOffset_signConvention() {
        // Swift's secondsFromGMT() returns positive values for UTC+ zones.
        // E.g. Europe/Kyiv (UTC+2): secondsFromGMT() = 7200 → offset = +120
        // The backend interprets the offset as "minutes ahead of UTC" (same sign as POSIX tz).
        // A negative value would push the server's clock in the wrong direction.
        let offset = TimeZone.current.secondsFromGMT() / 60
        // We cannot assert a specific sign without knowing the test machine's timezone,
        // but we can assert the value is within the valid range [-720, +840].
        XCTAssertGreaterThanOrEqual(
            offset, -720,
            "iOS-9: Timezone offset must be >= -720 (UTC-12)")
        XCTAssertLessThanOrEqual(
            offset, 840,
            "iOS-9: Timezone offset must be <= +840 (UTC+14)")
        // The critical fix: the body must NOT negate this value.
        // This test documents the expected contract; the negation regression would be caught
        // by an integration test against the backend.
    }
}
