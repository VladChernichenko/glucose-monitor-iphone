# Siri: "What is my blood sugar?" (short design)

## Intent and why
Ask Siri for the current glucose hands-free, mainly with the iPhone locked, and hear
"Your blood sugar is 5.6 mmol/L". No need to unlock and open the app.

## Goals
- Spoken answer with the value in the user's preferred unit (mmol/L or mg/dL).
- Works with the phone locked (after first unlock since boot).
- If the reading is old, say so ("Your last reading was 23 minutes ago: 5.6 mmol/L") instead of presenting it as current.
- Same behavior when unlocked.

## Non-goals
- No trend arrow, IOB/COB or prediction in the answer (can be added later).
- No new backend endpoint or push/silent-notification updates.
- No watch/CarPlay/HomePod-specific work (they may work for free; not tested).

## Anti-goals
- Never announce a stale value as current. A wrong-but-confident number is worse than "can't get it".

## Constraints found
- Min iOS 16.0: App Intents + App Shortcuts are available.
- Session tokens are in the shared Keychain with `AfterFirstUnlockThisDeviceOnly` → readable while locked, not before first unlock after reboot (answer "can't get reading").
- Snapshot (`LockScreenWidgetSnapshot`, App Group) is written by `AppState.persistWidgetSnapshot()`; its `savedAt` is the CGM sample time and `isStale(at:)` uses a 15-min cutoff plus the `dataStale` flag.
- For LibreLinkUp users the backend chart cache refreshes every ~5 min, so the freshest obtainable value is up to ~5 min behind the sensor (same as the dashboard). Nightscout users read via `fetchNightscoutEntriesWithFallbacks`.
- App Shortcuts phrases must contain the app name. The bare phrase "What is my blood sugar?" needs the user to record it in Shortcuts, and may collide with Apple Health.
- User must enable "Allow Siri When Locked".

## Approaches considered
- **A. Cache first, live fallback (chosen).** Fresh snapshot → answer instantly; else short-timeout fetch, update snapshot; else report last reading with its age.
- B. Cache only: simplest, but depends on iOS-scheduled background refresh, which can lag by hours.
- C. Always live: freshest, but adds latency and fails without signal.

## Design (A)
- New `AppIntent` in the main app target (not the widget extension: it needs `BackendAPI`), `authenticationPolicy = .alwaysAllowed`, `openAppWhenRun = false`.
- `AppShortcutsProvider` with phrases containing `\(.applicationName)` (e.g. "What is my blood sugar in \(.applicationName)").
- `perform()`:
  1. Load snapshot. If `glucoseValue != nil`, not `dataStale`, and reading age ≤ ~5 min → answer.
  2. Else fetch latest reading with a ~4 s timeout (LLU: chart-data endpoint; Nightscout: entries endpoint), rewrite the snapshot (reuse existing save path), answer.
  3. Else, if any cached value exists → "Your last reading was N minutes ago: X". Else → "I can't get your blood sugar right now" (also the not-signed-in and before-first-unlock cases).
- Spoken unit and formatting come from the snapshot's `glucoseUnit` / `GlucoseUnit`; one decimal for mmol/L, integer for mg/dL.
- Doc note for the user: optionally record the exact phrase "What is my blood sugar?" in the Shortcuts app.

## Left to the builder
- How the intent learns the data source (LLU vs Nightscout) outside `AppState` (likely a shared-defaults flag written by the app).
- Extracting the minimal "latest reading" fetch so it doesn't need the full `AppState`.
- Exact timeout and freshness thresholds (device-test the Siri time limit).
- Tests: age/stale decision and spoken-string formatting as pure functions; the intent itself verified manually on a device while locked.
