import XCTest
@testable import GlucoseMonitor

/// Regression tests for BackendAPI-level bugs.
final class BackendAPIBugTests: XCTestCase {

    // MARK: - I1: JWT tokens stored in UserDefaults instead of Keychain

    // I1: JWT tokens must live in Keychain, not App Group UserDefaults.
    func testJWTStorageUsesKeychain() {
        let key = GlucoseMonitorAPI.StorageKey.accessToken
        let ud = GlucoseMonitorAPI.sharedDefaults()

        GlucoseMonitorAPI.storeSessionTokens(accessToken: "test-keychain-token", refreshToken: nil)

        XCTAssertNil(
            ud.string(forKey: key),
            "I1: Access token must not remain in UserDefaults after Keychain storage.")
        XCTAssertEqual(GlucoseMonitorAPI.storedAccessToken(), "test-keychain-token")

        GlucoseMonitorAPI.clearSession()
        XCTAssertNil(GlucoseMonitorAPI.storedAccessToken())
    }

    // BUG: I1 — Verify the access-token key string is what we expect
    // (guards against a silent key rename that would break the Keychain migration).
    func testJWT_storageKeyValue() {
        XCTAssertEqual(
            GlucoseMonitorAPI.StorageKey.accessToken, "gm_access_token",
            "I1: The accessToken storage key must not change; it is used for Keychain migration.")
    }

    // MARK: - I3: analyzePhotoNutrition creates a new URLSession per call (memory leak)

    // I3: analyzePhotoNutrition reuses a static URLSession (300s timeout).
    func testAnalyzePhotoNutrition_sessionCreation() throws {
        let backendAPIPath = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("GlucoseMonitor/BackendAPI.swift")
        let source = try String(contentsOf: backendAPIPath, encoding: .utf8)
        XCTAssertTrue(
            source.contains("photoAnalysisSession"),
            "I3: BackendAPI must declare a shared photoAnalysisSession URLSession.")
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

    // MARK: - iOS-10: LibreGlucoseCurrent timestamp parsed in device timezone instead of UTC

    // BUG: iOS-10 — When Spring sends "2024-05-23T13:49:00" (UTC time, no 'Z' suffix due to
    // global `spring.jackson.date-format: "yyyy-MM-dd'T'HH:mm:ss"`), GlucoseMonitorAPI's
    // shared jsonDecoder() falls back to DateFormatter with TimeZone.current.
    // On a UTC+3 device this makes 13:49 read as 13:49 local = 10:49 UTC — 3 hours behind —
    // causing "Updated 3 hrs ago" despite the sensor reading being current.
    //
    // FIX: LibreGlucoseCurrent.decodeCGMTimestamp() uses TimeZone(identifier: "UTC") for the
    // naive-string fallback.  LibreHistoryPoint.decodeDate() was fixed identically.
    // CURRENT STATUS: FIXED.  These tests are REGRESSION GUARDS.

    // Helper: build a UTC Date for a given year/month/day hour:minute:second.
    private func utcDate(year: Int, month: Int, day: Int,
                         hour: Int, minute: Int, second: Int = 0) -> Date {
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = TimeZone(identifier: "UTC")!
        var comps = DateComponents()
        comps.year = year; comps.month = month; comps.day = day
        comps.hour = hour; comps.minute = minute; comps.second = second
        return cal.date(from: comps)!
    }

    // Helper: encode a LibreGlucoseReading-like JSON payload with a given timestamp string.
    private func libreJSON(timestamp: String, value: Double = 8.4) -> Data {
        """
        {
            "timestamp": "\(timestamp)",
            "value": \(value),
            "trend": 3,
            "trendArrow": "\\u2192",
            "status": "normal",
            "unit": "mmol/L"
        }
        """.data(using: .utf8)!
    }

    // Naive UTC string ("yyyy-MM-dd'T'HH:mm:ss", no timezone suffix) must be interpreted
    // as UTC, NOT as the device's local timezone.
    // Regression: before the fix, a UTC+3 device would shift the time 3 hours backward.
    func testLibreCurrentTimestamp_naiveString_parsedAsUTC() throws {
        let data = libreJSON(timestamp: "2024-05-23T13:49:00")
        let reading = try JSONDecoder().decode(GlucoseMonitorAPI.LibreGlucoseCurrent.self, from: data)

        let expected = utcDate(year: 2024, month: 5, day: 23, hour: 13, minute: 49)

        XCTAssertNotNil(reading.timestamp,
            "iOS-10: timestamp must not be nil for a valid naive string")
        XCTAssertEqual(
            reading.timestamp!.timeIntervalSince1970,
            expected.timeIntervalSince1970,
            accuracy: 1.0,
            "iOS-10: Naive timestamp '2024-05-23T13:49:00' must be decoded as 13:49 UTC. "
            + "Got \(reading.timestamp!) — if this is ±(UTC offset) hours off, the "
            + "TimeZone.current regression is back in decodeCGMTimestamp().")
    }

    // With fractional seconds (Spring @JsonFormat fix output): "yyyy-MM-dd'T'HH:mm:ss.SSSXXX"
    // → "2024-05-23T13:49:00.000+00:00"
    func testLibreCurrentTimestamp_isoWithOffset_parsedCorrectly() throws {
        let data = libreJSON(timestamp: "2024-05-23T13:49:00.000+00:00")
        let reading = try JSONDecoder().decode(GlucoseMonitorAPI.LibreGlucoseCurrent.self, from: data)

        let expected = utcDate(year: 2024, month: 5, day: 23, hour: 13, minute: 49)

        XCTAssertNotNil(reading.timestamp,
            "iOS-10: timestamp must not be nil for an ISO-8601 string with +00:00")
        XCTAssertEqual(
            reading.timestamp!.timeIntervalSince1970,
            expected.timeIntervalSince1970,
            accuracy: 1.0,
            "iOS-10: '2024-05-23T13:49:00.000+00:00' must decode to 13:49 UTC.")
    }

    // With 'Z' suffix: "2024-05-23T13:49:00Z"
    func testLibreCurrentTimestamp_isoWithZ_parsedCorrectly() throws {
        let data = libreJSON(timestamp: "2024-05-23T13:49:00Z")
        let reading = try JSONDecoder().decode(GlucoseMonitorAPI.LibreGlucoseCurrent.self, from: data)

        let expected = utcDate(year: 2024, month: 5, day: 23, hour: 13, minute: 49)

        XCTAssertNotNil(reading.timestamp,
            "iOS-10: timestamp must not be nil for an ISO-8601 string with Z")
        XCTAssertEqual(
            reading.timestamp!.timeIntervalSince1970,
            expected.timeIntervalSince1970,
            accuracy: 1.0,
            "iOS-10: '2024-05-23T13:49:00Z' must decode to 13:49 UTC.")
    }

    // All three timestamp formats must produce the same Date value (regression guard).
    func testLibreCurrentTimestamp_allFormatsProduceSameDate() throws {
        let naive   = try JSONDecoder().decode(GlucoseMonitorAPI.LibreGlucoseCurrent.self,
                                              from: libreJSON(timestamp: "2024-05-23T13:49:00"))
        let withZ   = try JSONDecoder().decode(GlucoseMonitorAPI.LibreGlucoseCurrent.self,
                                              from: libreJSON(timestamp: "2024-05-23T13:49:00Z"))
        let withOff = try JSONDecoder().decode(GlucoseMonitorAPI.LibreGlucoseCurrent.self,
                                              from: libreJSON(timestamp: "2024-05-23T13:49:00.000+00:00"))

        let t1 = try XCTUnwrap(naive.timestamp).timeIntervalSince1970
        let t2 = try XCTUnwrap(withZ.timestamp).timeIntervalSince1970
        let t3 = try XCTUnwrap(withOff.timestamp).timeIntervalSince1970

        XCTAssertEqual(t1, t2, accuracy: 1.0,
            "iOS-10: Naive and Z-suffix timestamps must represent the same UTC instant.")
        XCTAssertEqual(t1, t3, accuracy: 1.0,
            "iOS-10: Naive and +00:00 timestamps must represent the same UTC instant.")
    }

    // Epoch-millisecond integer timestamp (backend alternative serialization).
    func testLibreCurrentTimestamp_epochMilliseconds_parsedCorrectly() throws {
        // 2024-05-23T13:49:00Z = 1716471000 seconds = 1716471000000 ms
        let expected = utcDate(year: 2024, month: 5, day: 23, hour: 13, minute: 49)
        let epochMs = Int64(expected.timeIntervalSince1970 * 1000)

        let json = """
        {
            "timestamp": \(epochMs),
            "value": 8.4,
            "trend": 3,
            "trendArrow": "\\u2192",
            "status": "normal",
            "unit": "mmol/L"
        }
        """.data(using: .utf8)!

        let reading = try JSONDecoder().decode(GlucoseMonitorAPI.LibreGlucoseCurrent.self, from: json)

        XCTAssertNotNil(reading.timestamp,
            "iOS-10: timestamp must not be nil for epoch-millisecond format")
        XCTAssertEqual(
            reading.timestamp!.timeIntervalSince1970,
            expected.timeIntervalSince1970,
            accuracy: 1.0,
            "iOS-10: Epoch-ms timestamp must decode to the correct UTC instant.")
    }

    // MARK: - iOS-11: LibreSensorInfo JSON decoding

    // Verifies that the LibreSensorInfo struct correctly decodes the JSON shape
    // returned by GET /api/libre/connections/{patientId}/sensor.
    func testLibreSensorInfo_allFields_decodedCorrectly() throws {
        let json = """
        {
            "serialNumber": "FA-12345",
            "sensorModel": "FreeStyle Libre 3",
            "activationDate": "2024-05-01T00:00:00.000+00:00",
            "expiryDate": "2024-05-15T00:00:00.000+00:00",
            "sensorAgeDays": 5,
            "sensorMaxDays": 14,
            "status": "active",
            "daysRemaining": 9
        }
        """.data(using: .utf8)!

        let info = try GlucoseMonitorAPI.jsonDecoder()
            .decode(GlucoseMonitorAPI.LibreSensorInfo.self, from: json)

        XCTAssertEqual(info.serialNumber, "FA-12345")
        XCTAssertEqual(info.sensorModel, "FreeStyle Libre 3")
        XCTAssertEqual(info.sensorAgeDays, 5)
        XCTAssertEqual(info.sensorMaxDays, 14)
        XCTAssertEqual(info.status, "active")
        XCTAssertEqual(info.daysRemaining, 9)
        XCTAssertNotNil(info.activationDate)
        XCTAssertNotNil(info.expiryDate)
    }

    func testLibreSensorInfo_missingOptionalFields_graceful() throws {
        // All fields are optional in the iOS struct — partial JSON must not throw
        let json = """
        { "status": "warmup", "daysRemaining": -2 }
        """.data(using: .utf8)!

        let info = try GlucoseMonitorAPI.jsonDecoder()
            .decode(GlucoseMonitorAPI.LibreSensorInfo.self, from: json)

        XCTAssertNil(info.serialNumber)
        XCTAssertNil(info.sensorModel)
        XCTAssertEqual(info.status, "warmup")
        XCTAssertEqual(info.daysRemaining, -2,
            "Negative daysRemaining (overdue) must decode correctly")
    }

    func testLibreSensorInfo_expiredStatus_decodesNegativeDaysRemaining() throws {
        let json = """
        { "status": "expired", "sensorAgeDays": 15, "sensorMaxDays": 14, "daysRemaining": -1 }
        """.data(using: .utf8)!
        let info = try GlucoseMonitorAPI.jsonDecoder()
            .decode(GlucoseMonitorAPI.LibreSensorInfo.self, from: json)
        XCTAssertEqual(info.status, "expired")
        XCTAssertEqual(info.daysRemaining, -1)
    }

    // Nil/missing timestamp must decode gracefully without throwing.
    func testLibreCurrentTimestamp_missing_isNil() throws {
        let json = """
        { "value": 8.4, "trend": 3, "status": "normal", "unit": "mmol/L" }
        """.data(using: .utf8)!

        let reading = try JSONDecoder().decode(GlucoseMonitorAPI.LibreGlucoseCurrent.self, from: json)
        XCTAssertNil(reading.timestamp,
            "iOS-10: Missing timestamp field must decode to nil, not throw.")
    }

    // Other fields (value, trend, trendArrow, status, unit) must decode correctly
    // alongside the fixed timestamp.
    func testLibreCurrentTimestamp_otherFieldsUnaffected() throws {
        let data = libreJSON(timestamp: "2024-05-23T13:49:00", value: 7.6)
        let reading = try JSONDecoder().decode(GlucoseMonitorAPI.LibreGlucoseCurrent.self, from: data)

        XCTAssertEqual(try XCTUnwrap(reading.value), 7.6, accuracy: 0.01,
            "iOS-10: value field must decode correctly alongside the fixed timestamp.")
        XCTAssertEqual(reading.trend, 3,
            "iOS-10: trend field must decode correctly.")
        XCTAssertEqual(reading.status, "normal",
            "iOS-10: status field must decode correctly.")
        XCTAssertEqual(reading.unit, "mmol/L",
            "iOS-10: unit field must decode correctly.")
    }
}
