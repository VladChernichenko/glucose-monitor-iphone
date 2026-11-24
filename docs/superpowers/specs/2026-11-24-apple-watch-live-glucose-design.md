# Apple Watch: live glucose and alerts

Date: 2026-11-24
Repos touched: `glucose-monitor-be` (backend), `glucose-monitor-iphone` (phone app, `Shared/`, and the Xcode project that builds the watch app from `../glucose-monitor-watch/GlucoseMonitorWatch`).

## Why

The user now wears an Apple Watch and wants to stop pulling out the phone to check their glucose. Two uses:

1. **Glance**: current glucose and trend, on the wrist.
2. **Alerts**: the same alert banners the phone dashboard shows at the top, on the watch, and a tap on the wrist when a new one appears, even if that tap is sometimes late.

Today the watch app cannot show anything. It reads the lock-screen widget snapshot from App Group storage, but its entitlement has no App Group, watch App Group containers are not shared with the iPhone anyway, there is no WatchConnectivity code, and the watch has no login. It also maps most trend arrows to "~" and ignores staleness (audit 2026-11-24).

## Goals

- Watch app main screen: current glucose (large, coloured by range), correct trend arrow, reading age that keeps counting, 2 h prediction; greyed out with the reason when the data is stale.
- The phone dashboard's top banners on the watch, with the phone's exact wording:
  - **Libre stale** (orange): "LibreLinkUp isn't responding" / "No new readings from Libre" plus the "for N min" detail.
  - **Watch strip** (red when urgent, green when calm): Low now, Treating low, Low likely, High ahead (with correction or refusal), Insulin still landing, Small rise, Watching, Dip ahead.
- A watch-face complication (and Smart Stack widget) showing glucose + arrow, plus the strip headline where there is room.
- A wrist tap when a new urgent alert appears, from the watch's own background checks.
- Data as fresh as the backend's 5-min Libre sync, whether or not the phone app is running.

## Non-goals

- Logging notes, carbs or insulin from the watch; the hypo confirm sheet; sick-mode controls.
- The morning ISF suggestion banner (a settings change with buttons) and the late-protein note (it explains the chart). Phone only.
- A chart on the watch.
- On-time alerts. Without push (needs the paid Apple Developer account) the watch can only check a few times an hour. On-time alerts via APNs are a later project once the account is paid.
- Signing in on the watch itself.

## Anti-goals (fail even if it "works")

- An old reading shown as if current. Same 15-min rule as the phone widget (`LockScreenWidgetSnapshot.staleAfter`, backend freshness).
- A dose or carbs suggestion still shown after its recheck time. The phone hides it (`AppState.watchStrip(at:)`); the watch must too.
- Phone and watch signing each other out.
- Repeated taps for the same alert (buzz storms).
- Watch wording drifting from the phone's.

## Constraints

- **Free Apple Developer team**: provisioning profiles last 7 days, so the watch app needs the same weekly reinstall as the phone app; no push notifications; a cap on new App IDs per week (the complication extension adds one).
- **watchOS background budget**: an app whose complication is on the active watch face gets a few background refreshes an hour; without it, fewer. Alerts are only as timely as those refreshes. The user accepted late alerts.
- **Focus / Sleep mode**: an ordinary notification is silenced by Sleep or other Focus modes. Breaking through needs the time-sensitive notification entitlement, which may not be available on a free team. If not, a night-time low may arrive without a tap.
- **Single-use refresh tokens**: `AuthService.refreshToken` rotates and spends the token (`rotateRefreshToken`), so the watch needs its own token chain.
- **Backend load**: single instance, ~50-200 active users on a 10-connection pool. The dashboard calculation runs a full forecast; watch polling adds to it.

## Approaches considered

1. **Watch asks the backend itself (chosen).** The phone hands the watch a separate login once; the watch, its complication and its background checks get everything from the backend. Fresh regardless of the phone, works on watch Wi-Fi away from the phone. Costs changes in backend, phone and watch.
2. **Phone relays everything.** No backend change, but the phone app only refreshes when opened or when iOS grants a rare background slot, so data and alerts would often be an hour late. Rejected for a low alarm.
3. **Both** (phone also pushes when open). Extra sync logic for no gain: the backend is at least as fresh as the phone. Rejected.

## Design

### 1. Backend: a separate session for the watch

`POST /api/auth/device-session`, authenticated with the caller's access token. Returns a new access + refresh token pair for the same user, in the same `AuthResponse` shape as `/login`. The new refresh token starts its own rotation chain, so phone and watch refreshes never collide. "Log out everywhere" (`/logout-all` watermark) revokes it like any other token. Covered by the existing auth rate limiting.

### 2. Backend: one compact "glance" call

`GET /api/watch/glance` (authenticated; the watch sends its time zone the way the phone does). One round trip, because watch background time is a few seconds. Returns:

- newest reading: mmol, timestamp, trend/direction as stored (or none);
- stale cause: none / LibreLinkUp down / no new readings, from the same sources the phone uses (`LibreLinkUpSyncService.upstreamStatus`, `CgmFreshnessService`); Nightscout users never get a Libre cause;
- 2 h prediction (mmol);
- the watch strip, computed by the same dashboard path the phone's `POST /api/glucose-calculations/` uses (`calculateDashboard` → carb advice → `WatchStripService.evaluate`).

**Parity with the phone is a requirement, not a nicety.** `WatchStateHold` and the carb-advice hold are per user and shared by every caller, so if phone and watch built different requests for the same reading, the held strip could flip between their two answers. The glance must build the request exactly as the phone does:

- `currentGlucose` = the reading the phone would use (Libre users: the newest stored reading, which is what the phone reads from `chart-data`; Nightscout users: the same source the phone uses);
- `currentTrendMmolPerMin` = the phone's mapping: stored trend/direction → arrow (`NightscoutEntry.trendArrow`, LibreLinkUp trend 1-5) → velocity (`BackendAPI.trendArrowToVelocity`: ↑↑ 0.100, ↑ 0.067, ↗ 0.033, → 0, mirrored for falling, unknown 0). Do **not** leave it null: the server would then fill in `freshTrendMmolPerMin` (a slope), which differs from the phone's value;
- `clientTimeInfo` from the watch's clock and time zone, like the phone's.

A backend test asserts that for the same stored state the glance strip equals the strip from the phone's POST.

No caching: the strip also depends on notes, hypo events, settings and sick mode, and a stale cached strip is worse than the extra load (a few forecasts an hour per watch). Revisit only if load shows it.

The backend's `GlucoseAlertService` (push delivery stubbed until APNs) is the natural home for on-time alerts later; it is not used here.

### 3. Phone: handing the watch its login

- Activate a `WCSession` at launch.
- When signed in, the watch app is installed and the watch has no session (it asks via message, or the phone notices on launch/sign-in): call `/api/auth/device-session` and send the watch `{accessToken, refreshToken, backendURL, displayUnit, dataSource}` with `transferUserInfo` (queued, survives the watch being asleep).
- On sign-out: send a "signed out" message; the watch deletes its tokens and cached glance.
- When the display unit changes: update the watch via `updateApplicationContext`.

### 4. Watch app

- Stores its tokens in its own Keychain and uses the existing `GlucoseMonitorAPI` refresh logic (it is already compiled into the watch target). If its refresh token is rejected, it drops its tokens and asks the phone for a new session, as when it has none.
- Main screen, top to bottom: glucose + arrow; unit · "2 min ago" (live-updating); 2 h prediction; then the stale banner and/or watch strip, styled like the phone's (orange / red / green tint, bold headline, caption detail). When stale: value greyed, banner explains why. When not signed in: "Open the app on your iPhone to connect" and the watch requests a session from the phone.
- Fetches the glance on open, on pull/tap refresh, and in background refresh tasks. Saves the latest glance to its own (watch-side) App Group storage for the complication.
- **Shared code, one source of truth**: move to `Shared/` and use from both phone and watch:
  - trend arrow mapping (`NightscoutEntry.trendArrow` / LibreLinkUp trend → arrow);
  - `WatchStripText` (headline/detail) and the parts of `ChatFormatting` it needs;
  - `LibreStaleCause` title/detail;
  - the "hide a dose/carbs suggestion after its recheck time" rule.
- Drop the watch's own `trendEmoji` (source of the "~" bug).

### 5. Complication

A watchOS WidgetKit extension in the Xcode project (watch-side App Group shared with the watch app). It does not call the network; it reads the cached glance and is reloaded by the watch app after each fetch.

- Circular: value + arrow. Rectangular: value + arrow + age, and the strip headline when there is an alert. Inline: "6.8 → · 2m". Corner: value + arrow.
- Stale: dashes in grey (as the phone's lock-screen widget does).
- Smart Stack: higher relevance while an urgent alert is on.

### 6. Buzzing

After each glance fetch (foreground or background), the watch decides whether to post a local notification:

- **Buzz for** alerts that need the user to act (the user's decision, 2026-11-24): Low now, Low likely, High ahead, and a Libre stale cause.
- **Show only, no buzz**: Treating low, Carbs landing, Insulin landing, Small rise (they report what you already did, or say "no correction"), and the calm states Watching and Dip ahead.
- **Once per alert**: buzz when a buzzing alert's (state, reason) differs from the last one buzzed, or appears after none. A Libre stale cause buzzes once per outage.
- **Low now**: buzz again at each recheck time (`nextCheckAt`) while it is still Low now.
- After sign-out or a long gap (no glance for over 30 min), the first glance does not buzz for an alert older than its recheck time.
- Notification text = the strip's headline and detail, so it reads like the phone banner.

This decision is a pure function (previous alert, new glance, now) → buzz or not, kept in `Shared/` and unit-tested.

### Delivery order

Each step is usable on its own:

1. Backend: device-session + glance endpoints (with tests).
2. Phone: WatchConnectivity handoff; shared code moved to `Shared/`.
3. Watch app: sign-in handoff, glance screen, banners, arrow and stale fixes.
4. Complication + background refresh.
5. Buzzing.

## Calls made without the user (check these)

- One new `glance` endpoint instead of the watch making the phone's three calls (upstream status, chart data, calculations): fewer round trips in a short background window, and the server picks the data source.
- Device-session endpoint instead of re-logging in from the phone with the stored password (which may be absent and would send the password around again).
- The glance mirrors the phone's request exactly (reading and arrow-based trend) rather than using the server's own trend slope, so the shared alert hold never sees two different answers.
- No server-side caching of the glance.
- Complication reads only the cache; the watch app does all network work.
- Minimum watchOS raised from 8.0 to 10.0 (WidgetKit complications and Smart Stack). Assumes the user's watch runs watchOS 10 or newer.
- Re-buzzing Low now at each recheck time; no buzz on the first glance after a long gap for an alert already past its recheck time.

## Left to the builder

- Before starting: confirm the user's watch runs watchOS 10+ (Xcode → Devices and Simulators with the watch connected).
- Exact JSON field names of the glance response.
- How the watch requests a session when it has none (message vs. application context), and retry on failure.
- Background scheduling details (`WKApplicationRefreshBackgroundTask` cadence, background `URLSession` if needed).
- Whether the free team can use the time-sensitive notification entitlement; fall back to a normal notification if not.
- Complication layouts within the families above.
- Test approach per repo: backend tests for both endpoints (auth, token-chain independence, freshness, Nightscout users, glance strip = phone POST strip); iOS unit tests for the moved shared code and the buzz decision; watch build on the simulator and a check on the real watch.
