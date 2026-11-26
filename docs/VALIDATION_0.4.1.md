# HealthDataBridge 0.4.1 (9): validation report

Date: November 26, 2026. Base commit: `d4af83202cd4d26053167c25a4f7308d9e3449bb`
(`main` after PRs #35 to #41), with the Xcode project set to `MARKETING_VERSION`
0.4.1 and `CURRENT_PROJECT_VERSION` 9. Previous release: 0.4.0 (8), tag `0.4.0` at
`6d327ca`.

Status: release built from source. Automated checks passed. No device check of
0.4.1 (9) has been reported; the device checks below are not executed. No IPA,
TestFlight or App Store build was published.

## Evidence executed

Environment: macOS 27.3, Xcode 27.2 (27B52), Apple Swift 6.4.2, macOS 27.2 host SDK,
iOS Simulator 27.2 SDK. All runs used the release worktree at the base commit with
the 0.4.1 (9) project change. Fixtures are synthetic.

| Evidence | Result | Limits |
| --- | --- | --- |
| E01: `swift test --jobs 2` | 124 passed, 0 failures | Core package only; no real WHOOP or HealthKit |
| E02: `bash scripts/verify_local.sh` | Exit 0. Auth, API, repository, engine, ViewModel (17 scenarios), HealthKit sample factory, App Intents and sync coordinator smoke checks passed; plist/entitlements lint, localization key parity and capability lint passed | iOS sources typechecked against the macOS SDK with service doubles |
| E03: `xcodebuild` Debug build, generic iOS Simulator, `CODE_SIGNING_ALLOWED=NO` | Exit 0, no errors or warnings in the quiet log | Compiles the app; runs no test and no HealthKit query |

Not executed for this release: isolated simulator native/UI suites, Release iPhone
build and signing check, update test over 0.4.0 (8), visual QA.

GitHub Actions: the merges of PRs #39 to #41 did not wait for GitHub Actions. They
relied on local runs of `swift test --jobs 2`, `scripts/verify_local.sh` and, for
#41, the simulator build. E01 to E03 repeat those runs on the combined `main`.

## Changes and covering checks

"Compile only" means E02/E03 compile the change but no test exercises it.

| Change | PR | Covering check | Pending or device result |
| --- | --- | --- | --- |
| Concurrent callers share one token refresh | #39 | E02 auth smoke: two concurrent `validAccessToken()` calls on an expired bundle send one Cognito request and return equal tokens | Not executed on device |
| A refresh overtaken by sign-in keeps the new session | #39 | E02 auth smoke: refresh held, sign-in as `new@example.com`, release; the store keeps the new email and tokens, the stale refresh throws `sessionChanged` | Token refresh during sign-in on device: not executed |
| A refresh that ends after Disconnect does not restore tokens | #39 | E02 auth smoke: refresh held, `disconnect()`, release; the store stays empty and the status stays disconnected | Not executed on device |
| Recovery `Retry-After` capped at 24 hours in the client | #40 | E02 API smoke: one-year `Retry-After` as seconds and as an HTTP date defers 24 hours (±5 s); `120` stays about 120 s | Real WHOOP rate limits |
| Stored far-future recovery deadline capped on read and save | #40 | E01: `testFarFutureRetryDeadlineIsCappedAtTwentyFourHours` | None locally |
| Sign-in page load failure shows a message and Retry | #41 | Compile only (E02/E03); E02 localization key parity | Retry with the phone offline: not executed |
| Version row in Options > About | #41 | Compile only (E03); E02 localization key parity | Version row on device: not executed |
| `scripts/install_on_device.sh` | #38 | `shellcheck` and `bash -n` in PR #38; not rerun for this report | The PR author installed 0.4.0 (8) with it |
| 0.4.0 device-check records | #35 to #37 | E02 (docs only) | Not applicable |

## Device checks not executed for 0.4.1

- Sign-in page Retry: open the WHOOP sign-in with the phone offline, see the message,
  go online and tap **Retry**.
- Options > About shows "0.4.1 (9)".
- Token refresh during sign-in: sign in again while a sync refreshes an expired token,
  then confirm the new account stays connected.

## Reproduction

Reproduce E01 to E03 from the repository root:

```sh
swift test --jobs 2
bash scripts/verify_local.sh
xcodebuild -quiet -project iOS/WHOOPHealthSync.xcodeproj -scheme WHOOPHealthSync \
  -sdk iphonesimulator -destination 'generic/platform=iOS Simulator' \
  -derivedDataPath /tmp/hdb-dd-R041 CODE_SIGNING_ALLOWED=NO build
```

Logs, binaries, signing files, device identifiers and state copies stay outside Git.
