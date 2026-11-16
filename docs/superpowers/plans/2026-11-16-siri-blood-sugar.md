# Siri "What is my blood sugar?" Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Ask Siri for the current glucose with the phone locked and hear "Your blood sugar is 5.6 mmol/L".

**Architecture:** An App Intent in the main app target answers from the cached `LockScreenWidgetSnapshot` when it is at most 5 minutes old, otherwise fetches the latest reading from the backend with a ~4 s timeout, otherwise reports the last cached reading with its age. Decision logic and spoken text are pure, unit-tested types; the intent is a thin wrapper and does not depend on `AppState`.

**Tech Stack:** Swift 5, SwiftUI app, AppIntents (iOS 16.0 floor), XCTest, hand-edited `project.pbxproj`.

**Spec:** `docs/superpowers/specs/2026-11-16-siri-blood-sugar-design.md`

## Global Constraints

- Min iOS 16.0; Swift 5 language mode; all new files go in the `GlucoseMonitor` app target (tests in `GlucoseMonitorTests`), flat in `GlucoseMonitor/` like `WatchStrip.swift`.
- Cache is "fresh" when reading age ≤ 5 min and `dataStale` is not set; no network call in that case.
- Live fetch timeout 4 s (`SiriGlucoseResolver.fetchTimeout`); on failure/timeout/empty answer from cache.
- Spoken value in the user's display unit (`StorageKey.glucoseDisplayUnit`, default "mmol/L"): mmol/L one decimal ("5.6 mmol/L"), mg/dL integer ("101 mg/dL"). No trend arrow, no IOB/COB.
- A reading older than 15 min (`LockScreenWidgetSnapshot.staleAfter`) or flagged stale is never spoken as current: "Your last reading was N minutes ago: X".
- Intent: `authenticationPolicy = .alwaysAllowed`, `openAppWhenRun = false`; phrases contain `\(.applicationName)`.
- Session tokens are Keychain `AfterFirstUnlock`; before first unlock after reboot the fetch fails and the cache/unavailable text is used.
- Commit messages end with `Co-Authored-By: Claude Sonnet 5.5 <noreply@anthropic.com>`. Run all git commands from `glucose-monitor-iphone/` (its own repo).

## Review Focus

- Reading timestamp slightly in the future (clock skew): treated as current, never "-1 minutes ago". (Task 1)
- Backend returns an empty list or only non-`sgv` entries: fall back to cache, no crash, no "0". (Tasks 2, 3)
- Fetched reading older than the cached one: keep the newer cache, don't overwrite it. (Task 2)
- Fetch hangs past the timeout: answer from cache within about timeout + margin. (Task 2)
- mg/dL user and snapshot with nil `glucoseValue` (the `empty` snapshot): speaks mg/dL integer; nil value counts as no cache. (Tasks 1, 3)

---

### Task 1: Spoken answer and freshness rules

**Files:**
- Create: `GlucoseMonitor/SiriGlucoseAnswer.swift`
- Test: `GlucoseMonitorTests/SiriGlucoseAnswerTests.swift`
- Modify: `GlucoseMonitor.xcodeproj/project.pbxproj` (add both files; follow the `WatchStrip.swift` entries at lines ~84, 225, 295, 598 for the app target and the `WatchStripTests.swift` entries for the test target; grep new IDs for uniqueness first)

**Interfaces:**
- Produces:
  ```swift
  struct SiriGlucoseReading: Equatable {
      var mmol: Double; var time: Date
      var deltaMmol: Double?; var trendArrow: String?; var flaggedStale: Bool
  }
  enum SiriGlucoseAnswer {
      static let freshCacheWindow: TimeInterval   // 5 * 60
      static let unavailableText: String          // "I can't get your blood sugar right now."
      static func isCacheFresh(_ r: SiriGlucoseReading, now: Date) -> Bool
      static func spokenText(_ r: SiriGlucoseReading?, displayUnit: String, now: Date) -> String
  }
  ```

- [ ] **Step 1: Write failing tests** in `SiriGlucoseAnswerTests` (`@testable import GlucoseMonitor`), using a fixed `now` and a helper `reading(mmol:ageMinutes:flaggedStale:)`:
  - `testCurrentMmol`: 5.6, 1 min, "mmol/L" → `"Your blood sugar is 5.6 mmol/L."`
  - `testCurrentMgdl`: 5.6 mmol, "mg/dL" → `"Your blood sugar is 101 mg/dL."`
  - `testStillCurrentAt15Minutes` (15 min → current wording) and `testOldReadingSaysAge`: 16 min → `"Your last reading was 16 minutes ago: 5.6 mmol/L."`
  - `testFlaggedStaleSaysAgeEvenWhenRecent`: 2 min + `flaggedStale` → `"Your last reading was 2 minutes ago: 5.6 mmol/L."`; 0-minute-old stale flagged → `"1 minute ago"` (minimum 1, singular)
  - `testHoursPhrasing`: 60 min → `"1 hour ago"`, 125 min → `"2 hours ago"`
  - `testNilIsUnavailable`: `nil` → `SiriGlucoseAnswer.unavailableText`
  - `testFutureTimestampIsCurrent`: reading 90 s in the future → current wording (Review Focus 1)
  - `testCacheFreshBoundary`: 5:00 old → true; 5:01 → false; `flaggedStale` at 1 min → false
- [ ] **Step 2: Run to verify failure** — build error "cannot find 'SiriGlucoseAnswer'". Command (background; redirect to a log, never pipe through `tail`; pick a simulator from `xcrun simctl list devices available` and pass an explicit `OS=`): `xcodebuild test -scheme GlucoseMonitor -project GlucoseMonitor.xcodeproj -destination 'platform=iOS Simulator,name=<name>,OS=<os>' -derivedDataPath /tmp/gm-derived CODE_SIGNING_ALLOWED=NO -only-testing:GlucoseMonitorTests/SiriGlucoseAnswerTests > /tmp/siri-t1.log 2>&1`
- [ ] **Step 3: Implement** `SiriGlucoseReading` and `SiriGlucoseAnswer` in `GlucoseMonitor/SiriGlucoseAnswer.swift`. Age = `max(0, now - time)`; "current" when age ≤ `LockScreenWidgetSnapshot.staleAfter` and not flagged; convert with `GlucoseUnit.fromMmol`/`isMgdl`; format with locale-neutral `String(format:)`.
- [ ] **Step 4: Run tests**, expect `** TEST SUCCEEDED **` in the log (`grep` it; check `$?` from the redirect, not a pipe).
- [ ] **Step 5: Commit** both files + pbxproj + the two docs under `docs/superpowers/` — `git add … && git commit -m "feat(siri): spoken glucose answer and freshness rules"` (with the Co-Authored-By line).

### Task 2: Resolver (cache first, live fallback, timeout)

**Files:**
- Create: `GlucoseMonitor/SiriGlucoseResolver.swift`
- Test: `GlucoseMonitorTests/SiriGlucoseResolverTests.swift`
- Modify: `project.pbxproj` (same pattern as Task 1)

**Interfaces:**
- Consumes: `SiriGlucoseReading`, `SiriGlucoseAnswer.isCacheFresh` (Task 1)
- Produces:
  ```swift
  struct SiriReadingSource {
      var loadCached: () -> SiriGlucoseReading?
      var fetchLatest: () async throws -> SiriGlucoseReading?
      var storeFetched: (SiriGlucoseReading) -> Void
  }
  enum SiriGlucoseResolver {
      static let fetchTimeout: TimeInterval   // 4
      static func resolve(_ source: SiriReadingSource, now: Date = Date(),
                          timeout: TimeInterval = fetchTimeout) async -> SiriGlucoseReading?
  }
  ```

- [ ] **Step 1: Write failing tests** with closure fakes that record calls:
  - `testFreshCacheDoesNotFetch`: fetch closure not called, returns cached.
  - `testStaleCacheFetchesAndStores`: returns fetched, `storeFetched` called once with it.
  - `testNoCacheFetches`: returns fetched.
  - `testFetchThrowsReturnsCache` / `testFetchNilReturnsCache` (Review Focus 2) / `testNoCacheAndFetchFailsReturnsNil`.
  - `testFetchedOlderThanCacheKeepsCache` (stale cache time T, fetched time T-60 s → returns cache, no store) (Review Focus 3).
  - `testSlowFetchTimesOutToCache`: fetch sleeps 2 s, `timeout: 0.05` → returns cache in < 0.5 s (Review Focus 4).
- [ ] **Step 2: Run** `-only-testing:GlucoseMonitorTests/SiriGlucoseResolverTests`; expect build failure for the missing type.
- [ ] **Step 3: Implement** `resolve`. Race `fetchLatest` against a `Task.sleep` inside a throwing task group; first result wins and the group is cancelled; any thrown error or timeout yields `nil` fetched.
- [ ] **Step 4: Run tests**; expect `** TEST SUCCEEDED **`.
- [ ] **Step 5: Commit** — `feat(siri): resolver with cache-first and fetch timeout`.

### Task 3: Real data source (backend fetch + snapshot bridge)

**Files:**
- Create: `GlucoseMonitor/SiriLiveReading.swift`
- Modify: `GlucoseMonitor/AppState.swift:519` (`private static func latestNightscoutEntry` → drop `private`, to reuse it)
- Test: `GlucoseMonitorTests/SiriLiveReadingTests.swift`
- Modify: `project.pbxproj`

**Interfaces:**
- Consumes: `SiriGlucoseReading`, `SiriReadingSource` (Tasks 1–2); `BackendAPI.fetchNightscoutChartData(count:since:)`, `BackendAPI.fetchNightscoutEntriesWithFallbacks(count:)`, `NightscoutEntry.toLibreGlucoseCurrent(isLLU:)`, `LockScreenWidgetSnapshot`, `GlucoseMonitorAPI.StorageKey.dataSource` / `.glucoseDisplayUnit`
- Produces:
  ```swift
  enum SiriLiveReading {
      static func latest(from entries: [BackendAPI.NightscoutEntry], isLLU: Bool) -> SiriGlucoseReading?
      static func reading(from snapshot: LockScreenWidgetSnapshot) -> SiriGlucoseReading?
      static func merged(_ r: SiriGlucoseReading, into snapshot: LockScreenWidgetSnapshot) -> LockScreenWidgetSnapshot
      static func displayUnit() -> String
      static var source: SiriReadingSource { get }
  }
  ```

- [ ] **Step 1: Write failing tests** (build `NightscoutEntry` the way existing tests do: `grep -rn NightscoutEntry GlucoseMonitorTests`, decoding JSON with `GlucoseMonitorAPI.jsonDecoder()`):
  - `latest`: picks the newest `sgv` entry regardless of array order; ignores non-`sgv` types; converts mg/dL → mmol (101 → ≈5.6); `deltaMmol` = newest − previous in mmol; `[]` and all-non-sgv → `nil` (Review Focus 2).
  - `reading(from:)`: snapshot with nil `glucoseValue` → nil (Review Focus 5); mg/dL snapshot (101) → mmol ≈5.6; `time` = `savedAt`; `flaggedStale` = `dataStale == true`.
  - `merged`: new value written in the snapshot's own unit, `savedAt = reading.time`, `dataStale = false`, `trendArrow` and `deltaValue` updated (delta converted to snapshot unit); `cobGrams`, `iobUnits`, `twoHourPredictionMmol`, `chartPoints` unchanged.
- [ ] **Step 2: Run** `-only-testing:GlucoseMonitorTests/SiriLiveReadingTests`; expect failure.
- [ ] **Step 3: Implement** the three pure functions, then `displayUnit()` (shared defaults, default "mmol/L"), then `source`: `loadCached` = `LockScreenWidgetSnapshot.load()` → `reading(from:)`; `fetchLatest` = if shared-defaults data source is `"nightscout"` use `fetchNightscoutEntriesWithFallbacks(count: 3)` else `fetchNightscoutChartData(count: 3)` (the same split `AppState.loadGlucoseHistory` uses), then `latest(from:isLLU:)`; `storeFetched` = merge into the loaded snapshot (skip when none exists), `save()`, then reload `LockScreenWidgetSnapshot.allWidgetKinds` via `WidgetCenter`.
- [ ] **Step 4: Run** the new tests plus the existing `AppStateBugTests` (verifies the `latestNightscoutEntry` visibility change); expect `** TEST SUCCEEDED **`.
- [ ] **Step 5: Commit** — `feat(siri): live reading fetch and snapshot bridge`.

### Task 4: App Intent, shortcut phrases, device verification

**Files:**
- Create: `GlucoseMonitor/CurrentGlucoseIntent.swift`
- Modify: `project.pbxproj` (app target only)

**Interfaces:**
- Consumes: `SiriGlucoseResolver.resolve`, `SiriLiveReading.source`/`displayUnit()`, `SiriGlucoseAnswer.spokenText`
- Produces: `struct CurrentGlucoseIntent: AppIntent` (title "Current Blood Sugar"), `struct GlucoseShortcuts: AppShortcutsProvider`

- [ ] **Step 1: Implement** `CurrentGlucoseIntent`: `authenticationPolicy = .alwaysAllowed`, `openAppWhenRun = false`, `perform() async throws -> some IntentResult & ProvidesDialog` returning `.result(dialog: IntentDialog(stringLiteral: spokenText))`. It must not touch `AppState`. `GlucoseShortcuts` registers the intent with phrases `"What is my blood sugar in \(.applicationName)"`, `"What's my glucose in \(.applicationName)"`, `"Check my blood sugar in \(.applicationName)"`, short title "Blood Sugar", `systemImageName: "drop.fill"`. If `authenticationPolicy` is unavailable at iOS 16.0, add `@available(iOS 17.0, *)` handling and note it in the commit message.
- [ ] **Step 2: Build** (simulator, `CODE_SIGNING_ALLOWED=NO`, log to file); expect `** BUILD SUCCEEDED **`. Then run the full `GlucoseMonitorTests` suite; the only acceptable failures are the pre-existing ones (`HypoPromptTests` ×3, `testJWTStorageUsesKeychain` under unsigned builds).
- [ ] **Step 3: Install on the physical device** (signed build; if profiles expired run `xcodebuild … -destination 'generic/platform=iOS' -allowProvisioningUpdates build`). On the device: Settings → Siri → enable "Allow Siri When Locked".
- [ ] **Step 4: Verify on the locked device**, expected result in brackets:
  1. Open the app once, then lock; say "Hey Siri, what is my blood sugar in <app display name>" → [speaks current value in your unit, e.g. "Your blood sugar is 5.6 mmol/L."].
  2. Force-quit the app, wait > 5 min, repeat → [still answers; value matches the dashboard after unlocking].
  3. Airplane mode, repeat → [if the cache is > 15 min old: "Your last reading was N minutes ago: …"; otherwise a normal answer].
  4. Optionally record the exact phrase "What is my blood sugar?" in the Shortcuts app and repeat.
- [ ] **Step 5: Commit** — `feat(siri): current-glucose App Intent and shortcut phrases`.
