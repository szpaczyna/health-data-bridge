# HealthDataBridge 0.4.1 (9) release notes

These notes cover the changes since tag `0.4.0`: PRs #35 to #41 and the release PR #42. Validation evidence for this release is in [VALIDATION_0.4.1.md](VALIDATION_0.4.1.md).

## Before you install

- 0.4.1 is build 9 with the same bundle identifier, `org.shpaq.WHOOPHealthSync`, as 0.4.0 (8). Built with the same signing team, it installs as an update over 0.4.0 and keeps your WHOOP session and sync data. No persistence or App Intent identifier changed.

## Changes in 0.4.1 (since 0.4.0)

### WHOOP connection
- A token refresh that was still running when you signed in again could save the previous account's tokens and email over the new sign-in. The app now discards that refresh and keeps the new session (#39).
- A token refresh that finished after Disconnect could put the tokens back into the Keychain. The app now stays disconnected (#39).
- Two parts of the app that need a fresh token at the same time now share one refresh request instead of sending two (#39).
- A recovery request that WHOOP answers with a very long `Retry-After`, as seconds or as a date, now pauses HRV import for at most 24 hours. The same limit applies to a deadline that 0.4.0 already saved, so an install stuck with a far-future date resumes HRV import within 24 hours of the update (#40).

### App screens
- If the WHOOP sign-in page fails to load, for example offline, the sign-in sheet shows "Could not load the WHOOP sign-in page. Check your connection and retry." and a **Retry** button instead of a blank page. The message is translated into Spanish and Polish (#41).
- Options > About shows the app version and build, for example "0.4.1 (9)" (#41).

### Build and tests
- `scripts/install_on_device.sh` builds the app and installs it on a paired iPhone with `devicectl`. Without an argument it picks the only paired physical iPhone; `-c Release` and `--launch` are optional. [Building](BUILDING.md) describes it (#38).
- New auth smoke cases cover concurrent refreshes and a refresh that overlaps sign-in or Disconnect. An API smoke case and `testFarFutureRetryDeadlineIsCappedAtTwentyFourHours` cover the 24-hour cap. `swift test` runs 124 tests.

### Documentation
- The 0.4.0 notes and report record the maintainer's device checks of 0.4.0 (8) on an iPhone 17 with iOS 27.3 (#35, #36, #37).
- [Building](BUILDING.md) now states the iOS 27.0 deployment target that the project sets (#42).

## Device checks

On the iPhone 17 with iOS 27.3, the maintainer reported the Version row in About, and an offline sync that stops with "Could not finish; retry required" and shows "The Internet connection appears to be offline." under Current issues. The sign-in page Retry and a token refresh during sign-in are still listed as not executed in [VALIDATION_0.4.1.md](VALIDATION_0.4.1.md). GitHub Actions results were not awaited; the automated results come from local runs.
