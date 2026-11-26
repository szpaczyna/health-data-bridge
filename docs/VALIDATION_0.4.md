# HealthDataBridge 0.4.0 (8): validation report

Date: November 26, 2026. Base commit: `a90995d5bf5d1a30ca1befb9bc4dbcc3c2299d05`
(`main` after PRs #26 to #32), with the Xcode project set to `MARKETING_VERSION`
0.4.0 and `CURRENT_PROJECT_VERSION` 8. Previous release: 0.3.1 (7), tag `0.3.1` at
`48e0b2e`.

Status: release built from source. Automated checks passed. The maintainer installed
0.4.0 (8) from Xcode on an iPhone 17 running iOS 27.3 and reported the device checks
listed under "Reproduction and physical acceptance" as working. An omission does not count as
approval. No IPA, TestFlight or App Store build was published.

Version drift: before this release the Xcode project declared 0.3.1 (7), while
README.md and VALIDATION_0.3.md described the candidate as 0.3.0 (7). 0.4.0 continues
the build sequence with build 8.

## Implementation reviewed

The changes fix findings 1 to 18 of a code audit of `main` at `48e0b2e`, plus one
smaller item (HRV read access query). PR #26, merged before the audit
fixes, makes manual sync read the readable part of a partly widened deferred window
and shrink the window after a clean run; it sits outside the findings table and is
covered by `testPartlyWidenedBoundaryRetriesReadablePartOnce` and
`testFailedOrCancelledRunKeepsWholeDeferredWindow`. Bundle identifier, signing team, Keychain
identifiers, store files, HealthKit metadata keys and the App Intent identity are
unchanged.

Sync engine: the read-visibility window ends at the run start, so a history window
older than the first Health data no longer fails the guard. The ongoing read guard
counts only samples from other sources. A revised night's own stages are also found
by WHOOP sleep ID. A reconnect is requested only when the session is lost. One
settled-status rule for recovery HRV is shared by the engine, the history importer and
the run summary. The previous operation summary is cleared before the sync lock is
taken.

Core reconciliation: an own heart-rate sample that exactly matches a WHOOP point is
kept even when a neighbouring point overlaps it. Sleep stages are clamped to the
session and to the previous stage; only invalid session bounds and a night with no
writable stage still fail.

WHOOP API: a rate-limit wait longer than the 30 s retry cap fails with a 429 instead
of sleeping. Reset headers such as `inf` and JSON IDs outside `Int64` fail without
trapping. The heart-rate route is logged and reported without the WHOOP user ID, and
the log sanitizer redacts `/user/<digits>`.

Contracts, repository and sign-in: the test-only `WhoopRecoveryReferenceAdapter` is
gone and the contract probe uses the importer's time-zone helpers. Session cookies
are accepted only from `whoop.com` and its subdomains. Stored sleep records match
within one second after a reload. External HRV read access is detected with a query
that excludes this app's samples.

UI: the unreachable recovery-HRV setup flow, its runtime methods, test and strings
are removed. **Stop import** appears only during a history import, a cancelled sync
adds no error, and cancelled runs show **Cancelled**. Error and event rows are
identified by position. Dead helpers are removed and `scripts/verify_local.sh` runs
its smoke checks through one function.

## Evidence executed

Environment: macOS 27.3, Xcode 27.2 (27B52), Apple Swift 6.4.2, macOS 27.2 host SDK.
All runs used the worktree at the base commit with the 0.4.0 (8) project change.
Fixtures are synthetic.

| Evidence | Result | Limits |
| --- | --- | --- |
| E01: `swift test --jobs 2` | 123 passed, 0 failures | Core package only; no real WHOOP or HealthKit |
| E02: `bash scripts/verify_local.sh` | Exit 0. Auth, API, repository, engine, ViewModel (17 scenarios), HealthKit sample factory, App Intents and sync coordinator smoke checks passed; plist/entitlements lint, localization key parity and capability lint passed | iOS sources typechecked against the macOS SDK with service doubles |
| E03: `xcodebuild` Debug build, generic iOS Simulator, `CODE_SIGNING_ALLOWED=NO` | Exit 0 | Compiles the app; runs no test and no HealthKit query |

Not executed for this candidate: isolated simulator native/UI suites, Release iPhone
build and signing check, the scripted binary update test with store comparison, visual
QA. The Xcode update on the maintainer's iPhone is recorded under "Reproduction and
physical acceptance".

GitHub Actions: several runs for PRs #27 to #32 and their merges into `main` were
cancelled or were still queued for lack of hosted runners. No run showed a failed
test step. The merges relied on the local runs of `swift test --jobs 2`,
`scripts/verify_local.sh` and the simulator build, run on each branch where the plan
required it and on the combined branches before each merge wave.

## Findings correspondence

E01 to E03 refer to the runs above. "Compile only" means E02/E03 compile the change
but no test exercises it.

| ID | Change | PR | Covering check | Pending or device result |
| --- | --- | --- | --- | --- |
| 1 | Read-visibility window anchored at run start | #27 | E02 engine: `testHistoryReadGuardIsAnchoredAtRunStart` | Real history import older than first Health data |
| 2 | Keep own HR samples that exactly match a point | #28 | E01: `testHeartRateCloselySpacedOwnSamplesAreNotDeletedOnResync` | None locally |
| 3 | Read guard counts only other sources | #27 | E02 engine: `testOngoingReadGuardIgnoresAppOwnedSamples` (fake models ownership) | Device: maintainer reported the predicate working |
| 4 | Own stages also found by WHOOP sleep ID | #27 | E02 engine: `testShortenedSleepDeletesStaleOwnStagesOutsideWindow` | Device: maintainer reported the predicate working |
| 5 | Clamp sleep stages instead of failing the night | #28 | E01: `testSleepNormalizerClampsStageOverrunningSession`, `testSleepNormalizerClampsOverlappingStage`, `testSleepNormalizerDropsZeroLengthStage`, `testSleepNormalizerThrowsWhenAllStagesAreOutsideSession`, `testSleepNormalizerThrowsForInvalidSessionBounds` | The invalid-bounds test also passes before the fix |
| 6 | Reconnect only on lost session | #27 | E02 engine: `testOnlyLostSessionsCountAsAuthenticationFailures` | Real Cognito throttling |
| 7 | Shared recovery settled-status rule | #27 | E01: `testRecoverySettledStatusesAgreeWithIncompleteResults`; E02 engine: `testPausedNativeExportSettlesRecovery`, `testHistoryImportFinishesWhenNativeExportPaused` | None locally |
| 8 | Rate-limit wait capped; defensive header and ID parsing | #29 | E02 API smoke: reset `inf`, long reset fails with 429 and no sleep above the cap, JSON ID `1e19` throws | Real WHOOP rate limits |
| 9 | User ID kept out of HR logs and errors; sanitizer redacts `/user/<id>` | #29 | E02 API smoke: HR route error without user ID, sanitizer assertion | `os_log` output on device |
| 10 | Summary cleared before sync lock | #27 | Compile only (E03); statement order checked in review | Lock contention on device |
| 11 | **Stop import** only during history; silent cancel | #32 | E02 ViewModel: `testCancelledSyncIsSilentAndOnlyImportIsImportingHistory` | Button visibility in `OptionsView`: compile only |
| 12 | Unreachable recovery-HRV flow removed | #32 | Compile only (E02/E03); E02 localization key parity | None |
| 13 | Reference adapter removed; probe uses importer helpers | #30 | E01: `testActivityTimeZoneMatchesImporterOverSleepOffset`, `PrivateRecoveryAdapterTests` | None locally |
| 14 | Shared run-status label with **Cancelled** | #32 | Compile only (E03); E02 localization key parity | Rendering on device |
| 15 | Positional IDs for error and event rows | #32 | Compile only (E03) | Rendering on device |
| 16 | Cookie domain limited to `whoop.com` and subdomains | #30 | E02 auth smoke: `evilwhoop.com` rejected, `app.whoop.com` accepted | Real WHOOP sign-in |
| 17 | Sleep records match within one second after reload | #30 | E02 repository smoke: sub-second record reloaded and merged | Relaunch with a real store |
| 18 | Dead helpers removed; one `run_smoke` function | #31 | E01, E02 (the script itself) | None |
| HRV access query | External HRV access query excludes own samples | #30 | Compile only (E03) | Device: maintainer reported the predicate working |

## Deferred, out of scope

- Token refresh racing a concurrent sign-in (`WhoopAuthService`).
- No load-failure handling on the WHOOP sign-in page (`WhoopLoginWebView`).
- Recovery `Retry-After`: the client stores the value WHOOP sends without a cap, so an
  unusually long value pauses recovery import until that time, across relaunches.

## Reproduction and physical acceptance

Reproduce E01 to E03 from the repository root:

```sh
swift test --jobs 2
bash scripts/verify_local.sh
xcodebuild -quiet -project iOS/WHOOPHealthSync.xcodeproj -scheme WHOOPHealthSync \
  -sdk iphonesimulator -destination 'generic/platform=iOS Simulator' \
  -derivedDataPath /tmp/hdb-dd-R CODE_SIGNING_ALLOWED=NO build
```

Physical acceptance: the maintainer installed 0.4.0 (8) from Xcode on an iPhone 17
running iOS 27.3 and reported these checks as working:

- HealthKit predicates on the device: the other-source read guard (finding 3), the
  WHOOP sleep ID stage query (finding 4) and the HRV read access query.
- Sync with a real WHOOP account.
- History import and recovery HRV with a real WHOOP account.
- Update over 0.3.1 (7): Xcode built 0.4.0 (8) and installed it onto the phone over
  the existing app.
- The Sync WHOOP Shortcut.

The report covers these outcomes only. A byte-level comparison of the sync store
across the update and a history import reaching back before the first Health data
were not reported separately.

Logs, binaries, signing files, device identifiers and state copies stay outside Git.
