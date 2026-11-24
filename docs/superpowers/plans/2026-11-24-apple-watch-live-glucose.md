# Apple Watch Live Glucose Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** The Apple Watch shows live glucose, trend and the phone dashboard's alert banners, fetched from the backend itself, with a watch-face complication and a wrist tap for alerts that need action.

**Architecture:** The backend gains a device-session endpoint (a second, independent token chain) and one `GET /api/watch/glance` call that builds the dashboard request exactly as the phone does. The phone hands the watch its session over WatchConnectivity. Display, wording, staleness and buzz rules live in `Shared/` (compiled into phone, watch and complication) so they are unit-tested in the phone test target and can't drift.

**Tech Stack:** Spring Boot 3 / Java 21 / JUnit 5 / Mockito / Testcontainers; SwiftUI, WatchConnectivity, WidgetKit (watchOS), UserNotifications, XCTest.

**Spec:** `glucose-monitor-iphone/docs/superpowers/specs/2026-11-24-apple-watch-live-glucose-design.md`

## Global Constraints

- Two repos, one branch each, cut from `main`: `glucose-monitor-be` → `feat/watch-glance`; `glucose-monitor-iphone` → `feat/apple-watch`. Watch sources live in `../glucose-monitor-watch/GlucoseMonitorWatch` (not a repo) and are built by the iphone repo's Xcode project; `Shared/` is tracked in the iphone repo.
- Minimum watchOS 10.0 for the watch app and the complication (`WATCHOS_DEPLOYMENT_TARGET = 10.0`, was 8.0).
- Stale = reading older than 15 min (`CgmFreshnessService.MAX_AGE`, `LockScreenWidgetSnapshot.staleAfter`) or a Libre stale cause.
- mg/dL ↔ mmol/L factor on the phone/watch side and for the glance's `currentGlucose`: **18.018** (`GlucoseUnit.mgdlPerMmol`), not 18.0.
- Phone-parity trend: LibreLinkUp trend 1…5 → ↓↓ ↘ → ↗ ↑↑ (anything else "?"); Nightscout direction DoubleUp ↑↑, SingleUp ↑, FortyFiveUp ↗, Flat →, FortyFiveDown ↘, SingleDown ↓, DoubleDown ↓↓, empty/NOT COMPUTABLE/RATE OUT OF RANGE/other →. Arrow → mmol/L/min: ↑↑ 0.100, ↑ 0.067, ↗ 0.033, → 0.000, ↘ −0.033, ↓ −0.067, ↓↓ −0.100, anything else 0.000.
- Wording is reused, never rewritten: `WatchStripText.headline/detail` and `LibreStaleCause.title/detail` produce every banner and notification string.
- Buzz for: LOW_NOW, FORECAST_LOW, HIGH_FORECAST, Libre stale cause. Show only: TREATING_LOW, CARBS_LANDING, INSULIN_LANDING, SMALL_RISE, WATCHING, DIP_AHEAD.
- No server-side caching of the glance.
- Bundle IDs: watch app `com.che.glucosemonitor.watchapp` (existing); complication `com.che.glucosemonitor.watchapp.complication`. App Group `group.che.glucosemonitor` on watch app and complication (watch-side container).
- Free Apple team: no push, 7-day profiles. Regenerate profiles with `xcodebuild -scheme GlucoseMonitor -project GlucoseMonitor.xcodeproj -destination 'generic/platform=iOS' -allowProvisioningUpdates build` when signing fails.
- Tests: run only the tests covering the task; full suites once at the end (Task 12).
- New Swift files must be added to `GlucoseMonitor.xcodeproj/project.pbxproj` by hand: PBXFileReference + group child + one PBXBuildFile per target + entry in each target's PBXSourcesBuildPhase. Follow the existing hand-made ID style (`6000…`/`7000…`, unique).
- Commit messages end with `Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>`.

## Commands

- Backend focused test: `cd glucose-monitor-be && ./gradlew test --tests '<FQCN>'` (Docker must be running for Testcontainers).
- iOS focused test (never pipe xcodebuild into tail/head; check the log):
  `cd glucose-monitor-iphone && xcodebuild test -scheme GlucoseMonitor -project GlucoseMonitor.xcodeproj -destination 'platform=iOS Simulator,name=iPhone 16,OS=18.3.1' -derivedDataPath /tmp/gm-derived CODE_SIGNING_ALLOWED=NO -only-testing:GlucoseMonitorTests/<Class> > /tmp/gm-test.log 2>&1; echo $?; grep -E '\*\* TEST (SUCCEEDED|FAILED)|error:' /tmp/gm-test.log`
- Watch build: `xcodebuild -scheme GlucoseMonitorWatch -project GlucoseMonitor.xcodeproj -destination 'platform=watchOS Simulator,name=Apple Watch Series 11 (46mm),OS=26.5' -derivedDataPath /tmp/gm-watch-derived CODE_SIGNING_ALLOWED=NO build > /tmp/gm-watch.log 2>&1; echo $?; grep -E '\*\* BUILD|error:' /tmp/gm-watch.log`

## Review Focus

- **Watch offline / backend unreachable:** the last glance stays on screen with its age; once the reading is over 15 min old the value greys out and the prediction and strip disappear. Pinned in Task 8 (`testOldReadingIsStaleAndHidesPredictionAndStrip`).
- **Expired dose advice on a cached complication:** an INSULIN/CARBS suggestion whose `nextCheckAt` has passed must not render. Pinned in Task 8 (`testExpiredDoseSuggestionHidesStrip`).
- **mg/dL user:** value, prediction and banner text all in mg/dL. Pinned in Task 8 (`testMgdlUserSeesMgdlEverywhere`).
- **Watch time zone missing or bogus:** the glance rejects a missing/invalid `tz` with 400 instead of computing in UTC. Pinned in Task 4 (`glance_invalidTimezone_returns400`).
- **Phone signs out while the watch is asleep:** the sign-out is queued (`transferUserInfo`, not `sendMessage`) and decodes on the watch into a clear-everything instruction. Pinned in Task 6 (`testSignOutIsQueuedNotMessaged`) and Task 5 (`testDecodeSignedOut`).

---

## Backend (`glucose-monitor-be`, branch `feat/watch-glance`)

### Task 1: Device session endpoint

**Files:**
- Modify: `src/main/java/che/glucosemonitorbe/service/AuthService.java`
- Modify: `src/main/java/che/glucosemonitorbe/controller/AuthController.java`
- Modify: `src/main/java/che/glucosemonitorbe/security/AuthRateLimitFilter.java:34`
- Create: `src/test/java/che/glucosemonitorbe/integration/AuthDeviceSessionIntegrationTest.java`
- Modify: `src/test/java/che/glucosemonitorbe/security/AuthRateLimitFilterTest.java`

**Interfaces:**
- Produces: `POST /api/auth/device-session` → 200 `AuthResponse {accessToken, refreshToken, tokenType:"Bearer", expiresIn}`; 401 without a valid bearer token. `AuthService.issueDeviceSession(String username): AuthResponse`.

- [ ] **Step 1: Write the failing integration test** (copy the Testcontainers/TestRestTemplate scaffolding and the `registerUser/login/refresh/me/post` helpers from `AuthSessionRevocationIntegrationTest`)

```java
@Test void deviceSession_withoutToken_is401() {
    assertEquals(HttpStatus.UNAUTHORIZED, post("/api/auth/device-session", null, null).getStatusCode());
}
@Test void deviceSession_returnsNewIndependentPair() {
    AuthResponse phone = login(registerUser());
    AuthResponse watch = deviceSession(phone.getAccessToken()).getBody();
    assertNotEquals(phone.getRefreshToken(), watch.getRefreshToken());
    assertEquals(HttpStatus.OK, me(watch.getAccessToken()).getStatusCode());
}
@Test void deviceSession_chainsRotateIndependently() {
    AuthResponse phone = login(registerUser());
    AuthResponse watch = deviceSession(phone.getAccessToken()).getBody();
    AuthResponse phone2 = refresh(phone.getRefreshToken()).getBody();
    AuthResponse watch2 = refresh(watch.getRefreshToken()).getBody();
    assertEquals(HttpStatus.OK, refresh(phone2.getRefreshToken()).getStatusCode());
    assertEquals(HttpStatus.OK, refresh(watch2.getRefreshToken()).getStatusCode());
}
@Test void deviceSession_isRevokedByLogoutAll() {
    AuthResponse phone = login(registerUser());
    AuthResponse watch = deviceSession(phone.getAccessToken()).getBody();
    post("/api/auth/logout-all", null, phone.getAccessToken());
    assertEquals(HttpStatus.UNAUTHORIZED, refresh(watch.getRefreshToken()).getStatusCode());
}
```

- [ ] **Step 2: Run it** — `./gradlew test --tests 'che.glucosemonitorbe.integration.AuthDeviceSessionIntegrationTest'`. Expected: FAIL (404/401 on the new path).
- [ ] **Step 3: Implement.** `AuthService.issueDeviceSession(username)` mints `tokenProvider.generateTokenFromUsername` + `generateRefreshToken` (random `jti`, so a fresh chain) and builds the `AuthResponse` like `login`. Controller method mirrors `logoutAllDevices`' authentication check (`/api/auth/**` is `permitAll`, so the controller must reject a missing/anonymous principal with 401 itself).
- [ ] **Step 4: Rate limit.** Add `"/api/auth/device-session"` to `LIMITED_PATHS`; add a test to `AuthRateLimitFilterTest` asserting that path is limited, mirroring the existing login case.
- [ ] **Step 5: Run both test classes.** Expected: PASS.
- [ ] **Step 6: Commit** `feat(auth): device-session endpoint for the Apple Watch`.

### Task 2: Phone-parity trend mapping

**Files:**
- Create: `src/main/java/che/glucosemonitorbe/watch/PhoneTrendParity.java`
- Create: `src/test/java/che/glucosemonitorbe/watch/PhoneTrendParityTest.java`

**Interfaces:**
- Produces: `PhoneTrendParity.arrow(Integer trend, String direction, boolean libreEntry): String` and `PhoneTrendParity.velocityMmolPerMin(String arrow): double` — Java copies of the phone's `NightscoutEntry.trendArrow` and `BackendAPI.trendArrowToVelocity` (values in Global Constraints). Class javadoc says it must stay identical to the Swift `TrendArrow` (Task 5).

- [ ] **Step 1: Write the failing parameterized tests** pinning every row: libre trend 1→"↓↓", 2→"↘", 3→"→", 4→"↗", 5→"↑↑", 0/6/null→"?"; every Nightscout direction in Global Constraints including null and "NOT COMPUTABLE"→"→"; every velocity including "?"→0.0 and null→0.0.
- [ ] **Step 2: Run** `./gradlew test --tests 'che.glucosemonitorbe.watch.PhoneTrendParityTest'`. Expected: FAIL (class missing).
- [ ] **Step 3: Implement** the two static methods as switch tables.
- [ ] **Step 4: Run.** Expected: PASS.
- [ ] **Step 5: Commit** `feat(watch): phone-parity trend mapping`.

### Task 3: Glance service

**Files:**
- Create: `src/main/java/che/glucosemonitorbe/watch/WatchGlance.java`
- Create: `src/main/java/che/glucosemonitorbe/watch/WatchGlanceService.java`
- Create: `src/test/java/che/glucosemonitorbe/watch/WatchGlanceServiceTest.java`

**Interfaces:**
- Consumes: `PhoneTrendParity` (Task 2); `CgmReadingRepository.findFirstByUserIdOrderByDateTimestampDesc`, `CgmFreshnessService.isStale(Optional<Long>, Instant)`, `LibreLinkUpSyncService.upstreamStatus(UUID).available()`, `UserDataSourceConfigService.getActiveConfigEntity(userId, LIBRE_LINK_UP)`, `GlucoseCalculationsService.calculateDashboard(GlucoseCalculationsRequest)`, `UserService.getUserByUsername`.
- Produces: `WatchGlanceService.glance(String username, ZoneId zone): WatchGlance` and the JSON the watch decodes (Task 5 mirrors it exactly):

```java
public record WatchGlance(Reading reading, StaleCause staleCause, Double twoHourPredictionMmol, WatchStrip watch) {
    public record Reading(double mmol, long at, Integer trend, String direction, boolean libre) {} // at = epoch ms
    public enum StaleCause { NONE, UPSTREAM_DOWN, NO_NEW_READINGS }
}
```

Rules (from the spec, mirroring `AppState.refreshCalculations` / `staleCause`):
- `reading` = newest stored row with sgv and timestamp, **whatever its age** (the phone also calculates from an old reading); `mmol = sgv / 18.018`; `libre` = user has an active LIBRE_LINK_UP config. No row → `reading` null, no calculation, prediction and watch null.
- `staleCause` (Libre users only; others always NONE): upstream not available → UPSTREAM_DOWN; else `CgmFreshnessService.isStale(newest)` → NO_NEW_READINGS; else NONE.
- Request: `currentGlucose = reading.mmol`, `currentTrendMmolPerMin = velocityMmolPerMin(arrow(trend, direction, libre))` (never null), `includePredictionFactors = true`, `userId = username`, `clientTimeInfo` = now in `zone` as `yyyy-MM-dd'T'HH:mm:ss`, `timezone = zone.getId()`, `timezoneOffset` = offset minutes (phone sends `secondsFromGMT/60`, positive east).
- `calculateDashboard` throwing a RuntimeException → log warn, return the glance with reading and staleCause, prediction and watch null.

- [ ] **Step 1: Write the failing Mockito tests**
  - `libreFreshReading_buildsPhoneEquivalentRequest`: sgv 126, trend 4 → captured request `currentGlucose` = 126/18.018 (±1e-9), `currentTrendMmolPerMin` = 0.033, `clientTimeInfo.timezone` = "Europe/Berlin"; glance carries the response's `twoHourPrediction` and `watch`.
  - `libreUpstreamDown_isUpstreamDown`, `libreOldReading_isNoNewReadings`, `nightscoutUser_neverHasLibreCause` (old reading, upstream mock down → NONE).
  - `noReading_returnsEmptyGlanceWithoutCalculating` (verify `calculateDashboard` never called).
  - `calculationFails_keepsReadingDropsStrip`.
- [ ] **Step 2: Run** `./gradlew test --tests 'che.glucosemonitorbe.watch.WatchGlanceServiceTest'`. Expected: FAIL.
- [ ] **Step 3: Implement** `WatchGlance` and `WatchGlanceService` (constructor injection plus a package-private constructor taking a `Clock`, as `WatchStripService` does).
- [ ] **Step 4: Run.** Expected: PASS.
- [ ] **Step 5: Commit** `feat(watch): glance service mirroring the phone's dashboard request`.

### Task 4: Glance endpoint and phone parity check

**Files:**
- Create: `src/main/java/che/glucosemonitorbe/watch/WatchGlanceController.java`
- Create: `src/test/java/che/glucosemonitorbe/integration/WatchGlanceIntegrationTest.java`

**Interfaces:**
- Consumes: `WatchGlanceService.glance` (Task 3).
- Produces: `GET /api/watch/glance?tz=<IANA id>` → 200 `WatchGlance` JSON (field names as in the record, `watch` serialized exactly as in the dashboard response); 400 when `tz` is missing or not a valid `ZoneId`; 401 unauthenticated.

- [ ] **Step 1: Write the failing integration tests** (Testcontainers scaffolding as in Task 1; seed readings with `CgmReadingRepository`)
  - `glance_unauthenticated_is401`.
  - `glance_invalidTimezone_returns400` (`tz=Mars/Base`) and missing `tz` → 400.
  - `glance_newUser_returnsEmptyGlance` → `reading` null, `staleCause` "NONE", `watch` null.
  - `glance_stripEqualsPhoneDashboardStrip`: seed fresh readings with sgv 58 (≈3.2 mmol/L), direction "Flat", for a user with no LibreLinkUp config (breaker closed), call the phone's `POST /api/glucose-calculations/` with the body the phone would send (`currentGlucose` = 58/18.018, `currentTrendMmolPerMin` 0.0, same `clientTimeInfo`), then `GET /api/watch/glance`; assert both `data.watch` and glance `watch` are non-null and equal as JSON trees, and `reason` is `LOW_NOW`.
- [ ] **Step 2: Run** `./gradlew test --tests 'che.glucosemonitorbe.integration.WatchGlanceIntegrationTest'`. Expected: FAIL.
- [ ] **Step 3: Implement** the controller (`@RequestMapping("/api/watch")`, `ZoneId.of(tz)` with `DateTimeException` → 400).
- [ ] **Step 4: Run Tasks 1–4 test classes.** Expected: PASS.
- [ ] **Step 5: Commit** `feat(watch): GET /api/watch/glance`.

---

## Phone and Shared (`glucose-monitor-iphone`, branch `feat/apple-watch`)

### Task 5: Shared display code (moves + new shared types)

**Files:**
- Create: `Shared/TrendArrow.swift`, `Shared/WatchStrip.swift`, `Shared/LibreStaleCause.swift`, `Shared/WatchGlance.swift`, `Shared/WatchHandoff.swift`
- Modify: `GlucoseMonitor/BackendAPI.swift` (`NightscoutEntry.trendArrow/lluTrendArrow/directionArrow`, `trendArrowToVelocity`, `parseBackendDate` delegate to Shared), `GlucoseMonitor/WatchStrip.swift` (keep only the `AppState` extension), `GlucoseMonitor/AppState.swift` (remove `LibreStaleCause`), `GlucoseMonitor/Chat/ChatItem.swift` (`ChatFormatting.glucose/clock/unitLabel` delegate to `GlucoseText`)
- Modify: `GlucoseMonitor.xcodeproj/project.pbxproj` — new Shared files in targets GlucoseMonitor and GlucoseMonitorWatch; also add `GlucoseMonitor/GlucoseUnit.swift` to GlucoseMonitorWatch.
- Create: `GlucoseMonitorTests/WatchSharedTests.swift`

**Interfaces (Produces):**
- `enum TrendArrow { static func arrow(trend: Int?, direction: String?, libreEntry: Bool) -> String; static func velocity(_ arrow: String?) -> Double; static func display(_ arrow: String?) -> String }` — `display` returns "→" for nil, empty or "?" (the lock-screen widget's rule).
- `enum BackendDate { static func parse(_ s: String) -> Date? }` (body moved from `parseBackendDate`).
- `enum GlucoseText { static func glucose(mmol: Double, unit: String) -> String; static func clock(_ date: Date) -> String; static func unitLabel(_ unit: String) -> String }`.
- Top-level `struct WatchStrip: Codable, Equatable` (moved verbatim from `BackendAPI.WatchStrip`, dates via `BackendDate.parse`); replace every `BackendAPI.WatchStrip` reference (app, `WatchStripView`, tests) with `WatchStrip` — no typealias; new `func suggestionExpired(at now: Date) -> Bool` (INSULIN/CARBS suggestion and `nextCheckAt < now`); `AppState.watchStrip(at:)` uses it. `enum WatchStripText` moved verbatim, using `GlucoseText`.
- `enum LibreStaleCause` moved verbatim; new `init?(_ cause: WatchGlance.StaleCause)`.
- `struct WatchGlance: Codable, Equatable { struct Reading: Codable, Equatable { mmol: Double; at: Date /* from epoch ms */; trend: Int?; direction: String?; libre: Bool }; enum StaleCause: String, Codable { case none = "NONE", upstreamDown = "UPSTREAM_DOWN", noNewReadings = "NO_NEW_READINGS" }; reading: Reading?; staleCause: StaleCause; twoHourPredictionMmol: Double?; watch: WatchStrip? }` — `watch` must round-trip through `Encodable` for the watch's cache, so add `Encodable` to `WatchStrip` (dates encoded back in the backend's format).
- `enum WatchHandoff { enum Message: Equatable { case session(accessToken: String, refreshToken: String, backendURL: String, displayUnit: String, dataSource: String), signedOut, displayUnit(String), requestSession }; func encode() -> [String: Any]; static func decode(_ dict: [String: Any]) -> Message? }` — dictionary carries `"v": 1` and `"kind"`.

- [ ] **Step 1: Write the failing tests** in `WatchSharedTests`:
  - `testLibreArrows` / `testNightscoutArrows` / `testVelocities`: every row from Global Constraints.
  - `testDisplayArrowFallsBackToFlat`: `display("?") == "→"`, `display(nil) == "→"`, `display("↗") == "↗"`.
  - `testGlanceDecodesBackendJSON`: decode `{"reading":{"mmol":6.8,"at":1795512143000,"trend":3,"direction":null,"libre":true},"staleCause":"NONE","twoHourPredictionMmol":6.2,"watch":null}` → `reading.at == Date(timeIntervalSince1970: 1795512143)`, `staleCause == .none`.
  - `testGlanceRoundTripsWithStrip`: decode a glance whose `watch` is the LOW_NOW strip JSON used in `WatchStripTests`, encode, decode again → equal.
  - `testDecodeSession` / `testDecodeSignedOut` / `testDecodeUnknownKindIsNil` (encode → decode round-trip; `["v":1,"kind":"bogus"]` → nil).
  - `testSuggestionExpired`: INSULIN suggestion, `nextCheckAt` 1 s ago → true; NO_ACTION → false.
- [ ] **Step 2: Run** `WatchSharedTests`. Expected: FAIL (types missing).
- [ ] **Step 3: Move and create the code as listed; update pbxproj.**
- [ ] **Step 4: Run `WatchSharedTests` and `WatchStripTests`.** Expected: PASS (WatchStripTests changes only the type name, which proves the move kept behaviour).
- [ ] **Step 5: Build the watch target** (Commands). Expected: `** BUILD SUCCEEDED **`.
- [ ] **Step 6: Commit** `refactor(shared): trend, strip text and stale cause shared with the watch`.

### Task 6: Phone hands the watch its session

**Files:**
- Create: `GlucoseMonitor/WatchSessionBridge.swift`
- Modify: `GlucoseMonitor/BackendAPI.swift` (add `issueDeviceSession`), `GlucoseMonitor/BackgroundRefreshService.swift` (`GlucoseMonitorAppDelegate.didFinishLaunching` activates the bridge), `GlucoseMonitor/AppState.swift` (`logout()` and `handleSessionCleared()` → `signedOut()`; `setPreferredGlucoseUnit` → `displayUnitChanged`; new `didSignIn()` → `pushSession()`), `GlucoseMonitor/SignInView.swift:155` and `GlucoseMonitor/OnboardingDataSourceView.swift:45` (call `appState.didSignIn()` after `checkAuthentication()`). Not from `AppState.init`: a launch must not mint a new device session; the watch asks when it has none.
- Modify: pbxproj (new file → GlucoseMonitor target; test file → GlucoseMonitorTests)
- Create: `GlucoseMonitorTests/WatchSessionBridgeTests.swift`

**Interfaces:**
- Consumes: `WatchHandoff` (Task 5); `POST /api/auth/device-session` (Task 1).
- Produces:
  - `BackendAPI.issueDeviceSession() async throws -> (accessToken: String, refreshToken: String)` via `authorizedRequest(path: "/api/auth/device-session", method: "POST")` + `performWithRefresh`.
  - `protocol WatchTransport: AnyObject { var canReachWatchApp: Bool { get }; func transferUserInfo(_ info: [String: Any]); func updateApplicationContext(_ ctx: [String: Any]) throws }` — production adapter wraps `WCSession.default` (`canReachWatchApp` = activated && isPaired && isWatchAppInstalled).
  - `final class WatchSessionBridge: NSObject, WCSessionDelegate { static let shared; init(transport: WatchTransport, issue: @escaping () async throws -> (String, String), context: @escaping () -> (backendURL: String, displayUnit: String, dataSource: String), isSignedIn: @escaping () -> Bool); func activate(); func pushSession() async; func signedOut(); func displayUnitChanged(_ unit: String); func handle(message: [String: Any]) async }`. `session(_:didReceiveMessage:replyHandler:)` forwards to `handle(message:)`; a `.requestSession` there calls `pushSession()` when `isSignedIn()`.

- [ ] **Step 1: Write the failing tests** with a `FakeTransport` recording calls:
  - `testPushSessionTransfersPayload`: issue returns ("a","r") → one `transferUserInfo` whose decode is `.session(accessToken:"a", refreshToken:"r", backendURL:…, displayUnit:"mmol/L", dataSource:"libre")`.
  - `testNoWatchAppNoIssue`: `canReachWatchApp = false` → issue closure never called, nothing transferred.
  - `testIssueFailureTransfersNothing`.
  - `testSignOutIsQueuedNotMessaged`: `signedOut()` with the watch app installed → exactly one `transferUserInfo` decoding to `.signedOut` (the transport has no live-message path, so queuing is the only route).
  - `testUnitChangeUpdatesContext`: `displayUnitChanged("mg/dL")` → `updateApplicationContext` decoding to `.displayUnit("mg/dL")`.
  - `testRequestSessionMessageTriggersPush`: `handle(message: WatchHandoff.Message.requestSession.encode())` while signed in → one session transfer; while signed out → none.
- [ ] **Step 2: Run** `WatchSessionBridgeTests`. Expected: FAIL.
- [ ] **Step 3: Implement** the bridge, the endpoint call and the four AppState hooks.
- [ ] **Step 4: Run** `WatchSessionBridgeTests`. Expected: PASS.
- [ ] **Step 5: Commit** `feat(phone): hand the Apple Watch its own session`.

---

## Watch (`../glucose-monitor-watch/GlucoseMonitorWatch`, built from the iphone repo)

### Task 7: Watch receives the session and fetches the glance

**Files:**
- Create: `WatchSessionReceiver.swift`, `GlanceClient.swift`, `GlanceStore.swift`
- Modify: `GlucoseMonitorWatch.entitlements` (App Group `group.che.glucosemonitor`), `GlucoseMonitorWatchApp.swift` (activate receiver at launch)
- Modify: pbxproj (new files → GlucoseMonitorWatch; `WATCHOS_DEPLOYMENT_TARGET = 10.0` in both watch configs)

**Interfaces:**
- Consumes: `WatchHandoff`, `WatchGlance` (Task 5); `GlucoseMonitorAPI.storeSessionTokens/storeBackendBaseURL/clearSession/refreshToken/effectiveBackendBaseURL/storedAccessToken/sessionClearedNotification`; `GET /api/watch/glance` (Task 4).
- Produces:
  - `final class WatchSessionReceiver: NSObject, WCSessionDelegate, ObservableObject { static let shared; @Published private(set) var isSignedIn: Bool; func activate(); func requestSessionIfNeeded() }` — `.session` stores tokens, base URL, unit (`StorageKey.glucoseDisplayUnit`) and data source in `GlucoseMonitorAPI.sharedDefaults()`; `.signedOut` calls `clearSession(notify: false)` (so it does not trigger a session request) and `GlanceStore.clear()`; `.displayUnit` updates the unit; on `sessionClearedNotification` (refresh rejected) it clears the glance and sends `.requestSession` via `sendMessage` when reachable.
  - `enum GlanceClient { static func fetch() async throws -> WatchGlance }` — `GET /api/watch/glance?tz=<TimeZone.current.identifier>` with bearer token; on 401 `refreshToken()` once and retry (pattern of `fetchLibreGlucoseHistory`).
  - `enum GlanceStore { static func save(_ g: WatchGlance, fetchedAt: Date); static func load() -> (glance: WatchGlance, fetchedAt: Date)?; static func clear() }` — JSON in `GlucoseMonitorAPI.sharedDefaults()` under `gm_watch_glance_v1`.

- [ ] **Step 1: Implement the three files and the entitlement/pbxproj changes.** (Logic worth testing lives in Shared and is covered by Task 5; this task is glue.)
- [ ] **Step 2: Build the watch target.** Expected: `** BUILD SUCCEEDED **`.
- [ ] **Step 3: Commit** `feat(watch): receive the session and fetch the glance`.

### Task 8: Glance screen

**Files:**
- Create: `Shared/GlancePresentation.swift` (targets GlucoseMonitor, GlucoseMonitorWatch)
- Modify: `../glucose-monitor-watch/GlucoseMonitorWatch/WatchRootView.swift` (rewrite; delete `trendEmoji` and the snapshot-based views)
- Create: `GlucoseMonitorTests/GlancePresentationTests.swift`

**Interfaces:**
- Consumes: `WatchGlance`, `TrendArrow.display`, `WatchStripText`, `LibreStaleCause`, `WatchStrip.suggestionExpired`, `GlucoseText`, `GlanceStore`, `GlanceClient`, `WatchSessionReceiver`.
- Produces: `struct GlancePresentation: Equatable { struct Banner: Equatable { let title: String; let detail: String; let urgent: Bool }; init(glance: WatchGlance, now: Date, unit: String); let valueText: String; let arrow: String; let unitLabel: String; let readingAt: Date?; let isStale: Bool; let predictionText: String?; let rangeColor: RangeColor; let stale: Banner?; let strip: Banner? }` (stale banner: `LibreStaleCause.title/detail(lastReading:now:)`, `urgent` false; strip banner: `WatchStripText.headline/detail`, `urgent` = state ≠ CALM) with `enum RangeColor { case low, inRange, high, urgent, none }` (thresholds of the old watch view: < 3.5 or ≥ 14 urgent, < 4.0 low, ≥ 10.0 high). Stale = reading nil, older than 15 min at `now`, or staleCause ≠ none; when stale, `predictionText` and `strip` are nil and `rangeColor` is `.none`. `strip` is nil also when `watch` is nil, not `isKnown`, or `suggestionExpired(at: now)`.

- [ ] **Step 1: Write the failing tests**
  - `testFreshMmolReading`: 6.8, trend 3 libre → "6.8", "→", prediction "6.2", not stale.
  - `testOldReadingIsStaleAndHidesPredictionAndStrip`: reading 16 min before `now` with a LOW_NOW strip → `isStale`, `predictionText == nil`, `strip == nil`.
  - `testUpstreamDownShowsStaleBanner`: `stale.title == "LibreLinkUp isn't responding"`.
  - `testExpiredDoseSuggestionHidesStrip`: HIGH_FORECAST with INSULIN suggestion, `nextCheckAt` 1 min before `now` → `strip == nil`.
  - `testStripTextMatchesPhone`: LOW_NOW → `strip.title == WatchStripText.headline(watchStrip, unit:)`, `strip.detail == WatchStripText.detail(watchStrip, unit:)`, `urgent == true`.
  - `testMgdlUserSeesMgdlEverywhere`: 6.8 mmol, prediction 6.2, unit "mg/dL", FORECAST_LOW strip with low 3.6 → value "123", prediction "112", strip title contains "mg/dL".
- [ ] **Step 2: Run** `GlancePresentationTests`. Expected: FAIL.
- [ ] **Step 3: Implement** `GlancePresentation`; rewrite `WatchRootView`: signed-out → "Open the app on your iPhone to connect" and `requestSessionIfNeeded()`; signed-in → value + arrow, unit · age (`Text(readingAt, style: .relative)`), 2h prediction, stale banner (orange tint) and strip banner (red/green tint, bold headline, caption detail) like the phone's `WatchStripView`; greyed value when stale; refresh on appear, on scene-active and via a button; each fetch saves to `GlanceStore`.
- [ ] **Step 4: Run** `GlancePresentationTests`. Expected: PASS. **Build the watch target.** Expected: `** BUILD SUCCEEDED **`.
- [ ] **Step 5: Commit** `feat(watch): glance screen with phone banners`.

### Task 9: Buzz decision

**Files:**
- Create: `Shared/AlertBuzzPolicy.swift` (targets GlucoseMonitor, GlucoseMonitorWatch)
- Create: `../glucose-monitor-watch/GlucoseMonitorWatch/AlertNotifier.swift`
- Create: `GlucoseMonitorTests/AlertBuzzPolicyTests.swift`

**Interfaces:**
- Produces:
  - `struct BuzzMemory: Codable, Equatable { var lastKey: String?; var lastRecheckBuzzed: Date?; var lastGlanceAt: Date? }`
  - `struct Buzz: Equatable { let title: String; let body: String }`
  - `enum AlertBuzzPolicy { static func decide(memory: BuzzMemory, glance: WatchGlance, now: Date, unit: String) -> (buzz: Buzz?, memory: BuzzMemory) }` — key = `"\(state)/\(reason)"` for buzzing strips, `"stale/<cause>"` for a stale cause; title/body from `WatchStripText` or `LibreStaleCause`.
  - `enum AlertNotifier { static func requestAuthorization(); static func post(_ buzz: Buzz) }` — `UNNotificationRequest`, interruption level `.timeSensitive` when the entitlement is granted, else `.active`; memory persisted in `sharedDefaults` under `gm_watch_buzz_memory_v1`.

Rules (spec §6): buzz when a buzzing key differs from `lastKey` or appears after none; LOW_NOW also buzzes when `nextCheckAt <= now` and `lastRecheckBuzzed` is not that `nextCheckAt`; a non-buzzing glance resets `lastKey` to nil; if `lastGlanceAt` is nil or over 30 min before `now`, do not buzz for an alert whose `nextCheckAt` is already past; always set `lastGlanceAt = now`.

- [ ] **Step 1: Write the failing tests**
  - `testLowNowBuzzesOnce`: first LOW_NOW → buzz; same glance again → no buzz.
  - `testLowNowRebuzzesAtRecheck`: `now` past `nextCheckAt` → buzz; again with same `nextCheckAt` → no buzz.
  - `testForecastLowAndHighForecastBuzz`.
  - `testShowOnlyReasonsNeverBuzz`: TREATING_LOW, CARBS_LANDING, INSULIN_LANDING, SMALL_RISE, WATCHING, DIP_AHEAD → nil.
  - `testLowNowAfterTreatingLowBuzzes` (key changed).
  - `testStaleCauseBuzzesOncePerOutage`: UPSTREAM_DOWN → buzz; again → none; NONE then UPSTREAM_DOWN → buzz.
  - `testNoBuzzForPastRecheckAfterLongGap`: `lastGlanceAt` 40 min ago, LOW_NOW with `nextCheckAt` past → nil.
  - `testBuzzTextIsPhoneWording`: `buzz.title == WatchStripText.headline(…)`, `body == WatchStripText.detail(…)`.
- [ ] **Step 2: Run** `AlertBuzzPolicyTests`. Expected: FAIL.
- [ ] **Step 3: Implement** the policy and `AlertNotifier`; call `requestAuthorization()` at first launch and run the policy after every successful fetch in `WatchRootView`.
- [ ] **Step 4: Run** `AlertBuzzPolicyTests`. Expected: PASS. **Build the watch target.** Expected: SUCCEEDED.
- [ ] **Step 5: Commit** `feat(watch): tap the wrist for alerts that need action`.

### Task 10: Background refresh

**Files:**
- Create: `../glucose-monitor-watch/GlucoseMonitorWatch/GlanceRefresher.swift`
- Modify: `GlucoseMonitorWatchApp.swift`, `WatchRootView.swift` (foreground fetches go through the refresher)

**Interfaces:**
- Produces: `enum GlanceRefresher { static func refresh() async; static func scheduleNext() }` — `refresh()` = `GlanceClient.fetch` → `GlanceStore.save` → `AlertBuzzPolicy.decide` → `AlertNotifier.post` → `WidgetCenter.shared.reloadAllTimelines()`; failures leave the store untouched. `scheduleNext()` asks `WKApplication.shared().scheduleBackgroundRefresh(withPreferredDate: now + 15 min, userInfo: nil)`; the app handles it with SwiftUI `.backgroundTask(.appRefresh)` calling `refresh()` then `scheduleNext()`.

- [ ] **Step 1: Implement**; schedule on launch and after every refresh.
- [ ] **Step 2: Build the watch target.** Expected: SUCCEEDED.
- [ ] **Step 3: Simulator check:** run the watch app on the paired Series 11 simulator, background it, trigger a refresh with Xcode's *Debug → Simulate Background Fetch*; check the store's `fetchedAt` advanced (log line in `refresh()`).
- [ ] **Step 4: Commit** `feat(watch): background glance refresh`.

### Task 11: Complication

**Files:**
- Create: `../glucose-monitor-watch/GlucoseMonitorWatchComplication/GlucoseComplication.swift`, `Info.plist` (`NSExtension.NSExtensionPointIdentifier = com.apple.widgetkit-extension`), `GlucoseMonitorWatchComplication.entitlements` (App Group)
- Modify: pbxproj — new target `GlucoseMonitorWatchComplication` (`com.apple.product-type.app-extension`, `SDKROOT = watchos`, `WATCHOS_DEPLOYMENT_TARGET = 10.0`, `PRODUCT_BUNDLE_IDENTIFIER = com.che.glucosemonitor.watchapp.complication`, team `TRRFV962PL`, automatic signing), its sources (`GlucoseComplication.swift`, `Shared/WatchGlance.swift`, `Shared/WatchStrip.swift`, `Shared/TrendArrow.swift`, `Shared/LibreStaleCause.swift`, `Shared/GlancePresentation.swift`, `GlucoseMonitor/GlucoseUnit.swift`, `Shared/GlucoseMonitorAPI.swift` for `sharedDefaults`, and `GlanceStore.swift`), an "Embed Foundation Extensions" copy phase on GlucoseMonitorWatch, and a target dependency watch → complication. Add a `GlucoseMonitorWatchComplication` scheme only if xcodebuild needs it.

**Interfaces:**
- Consumes: `GlanceStore.load`, `GlancePresentation`.
- Produces: a `Widget` with kind `"GlucoseWatchComplication"`, families `.accessoryCircular` (value + arrow), `.accessoryRectangular` (value + arrow + age; strip headline when present), `.accessoryInline` ("6.8 → · 2m"), `.accessoryCorner` (value + arrow). Stale → "--" in grey. Timeline: one entry now plus entries at +5/+10/+15 min (so staleness and expired suggestions take effect without a fetch), policy `.after(now + 15 min)`. `TimelineEntryRelevance(score: 100)` when `strip?.urgent == true`, else 0.

- [ ] **Step 1: Implement** the extension and the project changes.
- [ ] **Step 2: Build the watch target** (it now embeds the complication). Expected: SUCCEEDED, and `GMWatch.app/PlugIns/GlucoseMonitorWatchComplication.appex` exists under the derived data products.
- [ ] **Step 3: Simulator check:** add the complication to a face on the Series 11 simulator; it shows the stored glance.
- [ ] **Step 4: Commit** `feat(watch): glucose complication and Smart Stack widget`.

### Task 12: End-to-end check and full suites

- [ ] **Step 1: Full suites.** Backend `./gradlew test`; iOS full `GlucoseMonitorTests` (known pre-existing failures: the 3 `HypoPromptTests` and `BackendAPIBugTests.testJWTStorageUsesKeychain` under `CODE_SIGNING_ALLOWED=NO`). Anything else failing is a regression.
- [ ] **Step 2: Paired simulators + local backend.** Start the backend locally, point the phone app at it (`localIP` setting), run phone (iPhone 17 Pro Max) and watch (Series 11 46mm) simulators of pair `16FA8902…`; sign in on the phone → the watch leaves the "Open the app on your iPhone" state and shows the glance; sign out on the phone → the watch returns to it.
- [ ] **Step 3: Real devices.** Regenerate profiles (Global Constraints), install on the iPhone and the watch; confirm the watch runs watchOS 10+ (Xcode → Devices and Simulators). Check: glance matches the phone dashboard, the complication updates within ~15 min, a forced low (manual reading or test user) taps the wrist.
- [ ] **Step 4: Report** what was verified on real hardware and what was not (e.g. timing of background refreshes, Sleep-focus behaviour, whether `.timeSensitive` was granted on the free team).
