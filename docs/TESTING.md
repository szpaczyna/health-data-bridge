# Testing and evidence limits

## Core and service tests

```sh
swift test --jobs 2
bash scripts/verify_local.sh
```

Core tests cover normalization, overlap reconciliation, stable identifiers, recovery revisions, WAL/checkpoint recovery, bounded private-provider pagination, retry deadlines, account mismatch and incomplete history. Service checks cover authentication mocks, private-API transport mocks, persistence, legacy sleep/heart-rate scenarios, unified setup with recovery HRV, failed authorization, history import, metadata, App Intents and capability/privacy lint. Since 0.4.0 they also cover the read guard anchored at run start and ignoring app-owned samples, stale stages of a revised night, reconnect only on a lost session, rate-limit waits above the retry cap, user-ID redaction, the WHOOP cookie domain, sub-second sleep records after reload and silent sync cancellation. Public fixtures use synthetic identities and health values.

GitHub Actions runs core XCTest and `scripts/verify_local.sh`. It does not call WHOOP or write HealthKit samples. Hosted CI does not certify the physical iPhone acceptance cases below.

## Isolated simulator tests

Use Xcode 27 and a suitable runtime. **Never run synthetic HealthKit writes on your physical phone.** Tests enforce simulator-only guards and require a simulator name containing `WHOOP 0.2 QA`. This legacy harness name is deliberate.

Create/select a dedicated simulator, initialize Apple Health and resolve its authorization prompts. Choose the test scheme. For fixture-driven UI tests, pass:

```sh
xcodebuild -project iOS/WHOOPHealthSync.xcodeproj \
  -scheme WHOOPHealthSync -destination 'platform=iOS Simulator,id=YOUR_ISOLATED_SIMULATOR_UDID' \
  'SWIFT_ACTIVE_COMPILATION_CONDITIONS=DEBUG WHOOP_IOS27_SDK WHOOP_VALIDATION_BUILD' \
  CODE_SIGNING_ALLOWED=YES CODE_SIGN_IDENTITY=- -jobs 2 \
  -parallel-testing-enabled NO test
```

The fixture path is simulator-gated, requires the isolated name and is absent from physical-device builds. UI fixtures do not contact WHOOP. Native HealthKit tests write only UUID-isolated synthetic samples and delete their exact returned samples; they must not use a personal Health store.

Exercise full-read, limited-history and denied-read configurations separately. Authorization prompts and runtime availability matter; record skipped tests rather than reporting them as successes.

## 0.4.0 (8) local results

Run on November 26, 2026 at commit `a90995d` with Xcode 27.2 and Swift 6.4.2. Details,
the findings-to-test table and pending physical checks are in
[the 0.4.0 report](VALIDATION_0.4.md).

| Scope | Result |
| --- | --- |
| Core XCTest (`swift test --jobs 2`) | 123 passed, 0 failed |
| `scripts/verify_local.sh` | Passed; ViewModel smoke 17 scenarios |
| Generic iOS Simulator Debug build, unsigned | Passed |

No isolated simulator native/UI suite was run for 0.4.0.

## Development results before publication

| Scope | Passed | Failed | Skipped |
| --- | ---: | ---: | ---: |
| Core XCTest (0.2 candidate) | 81 | 0 | 0 |
| Complete iOS 27 native/UI suite | 15 | 0 | 1 |
| Complete iOS 26.4 native/UI suite | 9 | 0 | 7 |
| iOS 27 full-read native suite | 9 | 0 | 1 |
| iOS 27 limited-read native suite | 8 | 0 | 2 |
| Rename to HealthDataBridge: iOS 27 UI | 6 | 0 | 0 |

Service/capability checks also passed. Skips reflect RMSSD/runtime availability, the limited-access configuration, or physical file-protection behavior unavailable on Simulator. Earlier failed UI-harness attempts were corrected and followed by successful final runs. These counts cover overlapping suites, not unique tests to add together.

The maintainer reported a successful basic real-account test on a personal iPhone. Build 0.2.0 (6) was subsequently installed as an update and the three persisted synchronization files were verified byte-for-byte unchanged. This is basic personal acceptance, not exhaustive public-device certification. Private logs, raw observations and device identifiers are intentionally not published.

## Earlier local unified-design verification (before the 0.3 specification review)

The following results belong to the earlier local iteration, not acceptance of the
subsequent 0.3.0 (7) specification implementation. Current results and omissions are
recorded separately in [the P01–P24 report](VALIDATION_0.3.md):

- Core XCTest: 81 passed, zero failures.
- verify_local.sh: all authentication, API, repository, HealthKit factory, App Intent
  and capability checks passed, including 22 engine scenarios and 10 ViewModel scenarios.
- iOS 27 isolated UI: 9 passed, zero failures/skips. Includes fresh mocked login →
  combined setup, explicit HRV checks, HRV opt-out and persisted setup decisions,
  existing-installation daily sync/relaunch and cancelling unchanged settings.
- iOS 26.4 isolated UI: 5 passed, zero failures, 4 skipped because those fixtures
  specifically require iOS 27. The ordinary dashboard/sign-in/accessibility checks passed.
- iOS 27 native HealthKit/persistence suite: 9 passed, zero failures, 1 skipped
  (physical-device file protection is not established by this simulator).
- Unsigned generic simulator and generic iPhone builds passed. Signing identity,
  bundle identifier, Keychain strings, metadata namespaces and App Intent implementation
  were not changed.

An initial UI pass failed because the result summary was below the visible lazy-list
content (and the Spanish summary key needed localization). The summary was moved next
to the main action, localization corrected and the final full UI suite passed.

Screenshots were inspected for the unified setup, existing-installation result,
historical-period sheet and prior large-type/language states. Tests use synthetic
fixtures; no real-account request or installation/update on the personal iPhone was
performed in this verification. Existing physical acceptance limits still apply.

## Physical cases still requiring broader acceptance

Real permission revocation, exporter coexistence, large real histories, interruptions/restarts, rate limits across actual sessions, file protection while locked and updates across other users' accounts need explicit physical testing. Simulator mocks do not establish these outcomes. The declared history period is not a provider-certified absolute-history endpoint.
