# HealthDataBridge 0.4.0 (8) release notes

These notes cover every change in this fork (szpaczyna/health-data-bridge) since it split from upstream xoselourido/health-data-bridge at `0f95b07` ("Keep incomplete sync phases partial and revalidate 0.3 candidate"). The range `0f95b07..0.4.0` holds PRs #1 to #34 and three direct commits. Validation evidence for this release is in [VALIDATION_0.4.md](VALIDATION_0.4.md).

## Before you install

- The bundle identifier is `org.shpaq.WHOOPHealthSync` and the signing team changed. iOS treats this build as a different app from an upstream install: it starts with an empty sync store, needs a new WHOOP sign-in and new Health permissions. Samples the upstream app wrote stay in Apple Health under that app's source, and this app does not own or reconcile them.
- The app and test targets require iOS 27.0. Mac (Designed for iPad), Vision Pro and Mac Catalyst destinations are off.
- There is no background refresh. Shortcut automations remain the only scheduled sync.

## Changes in 0.4.0 (since 0.3.1)

### Sync and Apple Health data
- A history import that reaches back before your first Health data no longer fails forever on its first window (#27).
- The read check after the first sync counts only samples from other sources. Before, a revoked read permission went unnoticed and WHOOP data could be written on top of Apple Watch data (#27).
- When WHOOP revises a night, the app also removes its own old stages outside the new session window, so a shortened sleep no longer leaves extra minutes in Health (#27).
- Two heart-rate points less than one step apart no longer delete each other's samples (#28).
- A night with a stage slightly outside the session, or a 1 ms overlap, is clamped instead of rejected, so it no longer blocks the sleep checkpoint (#28).
- A manual sync reads the part of a deferred window that Health already allows and shrinks the window afterwards (#26).
- Stored sleep records match after a relaunch even when WHOOP sends milliseconds (#30).
- Recovery HRV uses one rule for "finished". A setup where WHOOP already exports HRV no longer ends every sync with issues, and the history import can finish (#27).
- The HRV read-access check ignores the app's own samples, so an external source added after a large import is detected (#30).

### WHOOP connection
- A temporary Cognito failure (throttling or a 5xx) no longer asks you to reconnect. Only a lost session does (#27).
- When the WHOOP rate limit asks for a wait longer than 30 s, the sync stops with a rate-limit error instead of sleeping for hours. Recovery requests keep their scheduled retry (#29).
- Malformed rate-limit headers or oversized IDs no longer crash the app (#29).
- The WHOOP user ID no longer appears in logs, saved errors or the diagnostics report (#29).
- Sign-in accepts WHOOP cookies only from `whoop.com` and its subdomains (#30).

### App screens
- "Stop import" appears only during a history import. Cancelling a sync no longer shows a raw `CancellationError` message (#32).
- Cancelled runs show "Cancelled" instead of "Unknown" on the dashboard and the Activity screen (#32).
- Repeated error and event messages each show as their own row (#32).
- If a Shortcut holds the sync lock when you tap Sync, the app no longer shows the previous run's numbers as current (#27).

### Removed
- The separate recovery-HRV setup and import screens' logic, which no screen could open, with its strings (#32).
- `WhoopRecoveryReferenceAdapter`, which only tests used (#30), and helpers that no caller needed (#31).

### Build and tests
- `scripts/verify_local.sh` runs the smoke checks through one function and cleans its temporary binaries even when a check fails (#31).
- New XCTest and smoke scenarios cover each fix above. `swift test` runs 123 tests.

## Changes from the fork point to 0.3.1

### Sync and Apple Health data
- Late heart-rate uploads from WHOOP are revisited after an incremental sync (#4).
- Recovery history continues past a night with no verifiable time zone, and finishes when such a night has no Health journal (#5).
- Sleep discovery asks WHOOP in 7-day slices, so a gap longer than about seven weeks no longer drops nights (#18).
- The sleep checkpoint advances under a limited iOS 27 HealthKit read boundary. Deferred windows are kept for later manual runs (#19).
- The sync store reopens after a failed load on a locked device (#20).
- The read guard asks HealthKit for one sample per type instead of loading 30 days of heart rate (#11).
- Log events are saved with the next store save instead of on every event (#21). Events since the last save are lost if the app is killed during a run.

### Shortcuts
- A busy sync reports "sync in progress". A second automation call shares the running sync and waits up to 25 s for the lock (#9, #10).
- Shortcut results appear in the app's Summary and Last synced sections (#12).

### WHOOP connection
- Sign-in uses the WHOOP web page, because WHOOP rejects native password sign-in. Token refresh stays native (#6, #7).
- The API client paces requests (100 per minute, 10,000 per day), reads the rate-limit headers and backs off on 429 and 5xx responses (#1).

### App screens and languages
- Polish is a fourth language. Activity events, log messages, Shortcut dialogs and diagnostics follow the app language (#1, #5, #8, #9, #25).
- An appearance picker (system, light, dark) is in Options (#1).
- Saved runs keep per-phase results and their error list (#12, #13, #16).

### Build, project and CI
- The project targets Xcode 27 and iOS 27 only, with the `org.shpaq` bundle identifiers (#1, #2, `48e0b2e`).
- Background refresh was added and later removed (#1, #3, #22).
- CI runs `swift test` and `verify_local.sh`, pins `actions/checkout` by SHA and cancels superseded runs (#15). `verify_local.sh` fails on a missing localization key in any language (#13).
- Core checks moved into the XCTest target (#24).
- `SyncCoordinator` owns the sync lock and Shortcut coordination; `SyncRunStatus` replaces status strings (#13, #14, #23).

## Device checks

The maintainer installed 0.4.0 (8) from Xcode on an iPhone 17 running iOS 27.3 over the existing 0.3.1 install and reported these working: the HealthKit queries on the device, sync, history import and recovery HRV with a real WHOOP account, the update itself and the Sync WHOOP Shortcut. GitHub Actions runs were cancelled or queued for lack of hosted runners, so the automated test results come from local runs. See [VALIDATION_0.4.md](VALIDATION_0.4.md).
