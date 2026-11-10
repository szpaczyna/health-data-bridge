# HealthDataBridge 0.3.0 (7) — validation report

Date: September 15, 2026. Base: 0.2.0 (6), commit
`db6866ecf57578316e581b9a7532ebb4f6c5c680`.

Status: release candidate, not an accepted new physical installation. The matrix
distinguishes automated verification from full acceptance. An omission does not count
as approval. No real WHOOP has been contacted, this candidate has not been installed
on the personal iPhone, no IPA has been published, and it has not been distributed
through TestFlight/App Store.

## Implementation reviewed

Bundle, signing team, Keychain, directory, and persistence scheme are preserved, along
with HealthKit identifiers/fingerprints/versions/metadata and the App Intent identity.
There are no history queries or Health writes when opening the application.

The form uses a draft. The joint request returns the write per type and observable
read boundaries; neither a completed request nor an empty query equates to read
permission. Denied HRV allows keeping the base authorization and continuing without
it. Confirmations are reviewed again, and no native boundary is replaced by a manual
declaration. WHOOP is not identified by name.

Initial account, HRV selection, and marker are saved in a single protected and atomic
write. Failure reverts memory to the confirmed snapshot. The runtime revalidates
account, permissions, and source when saving and executing. First-time setup starts a
single recent sync; saving an existing configuration does not sync or change its
date/cursor. A saved configuration survives a subsequent network failure. Global
failures preserve results from confirmed phases.

History has its own start, cutoff, next window, and phase. Explicit HRV expansion is
saved together with its traversal; records, pending items, and WAL are preserved. The
cutoff also limits the recent HRV phase when resuming; it does not rewind its daily
discovery. An empty response with limited reading does not confirm the window. Daily
sync and Shortcuts do not resume the traversal.

## Evidence executed

Environment: macOS 26.6.2, Xcode 27.0 (27A266a), Swift 6.4; isolated iOS 27.0 and
iOS 26.4 simulators. Fixtures and integration samples are synthetic. Physical binaries
exclude UI fixtures via build conditions.

| Evidence | Result | Limits |
| --- | --- | --- |
| E01: `swift test --jobs 2` | 85 passed, 0 failures | Core, not real WHOOP or Health |
| E02: `bash scripts/verify_local.sh` | All checks passed; engine 22 scenarios, ViewModel 13 | Auth/MFA, transport/401/429, repository, engines, ViewModel, Shortcuts, samples and capabilities; service doubles |
| E03: iOS 27 native/UI suite | 21 passed, 2 skipped, 0 failures | Simulator's existing read profile; physical protection and older-iOS-exclusive case skipped |
| E04: iOS 26.4 native/UI suite | 12 passed, 11 skipped, 0 failures | RMSSD unavailable; iOS 27-specific cases and physical protection skipped |
| E05: Release iPhone build | Passed; valid signature and same identity; no UI fixtures | Does not imply physical installation or execution |
| E06: binary update on iOS 26.4 | 0.2.0 (6) → 0.3.0 (7), HRV enabled and disabled: store and WAL identical after launch | Synthetic state; no real token, previous Health samples, or subsequent sync |
| E07: visual QA | ES/EN configuration, confirmations, result, history, and large text inspected | Does not replace a complete VoiceOver spoken walkthrough |

After the last WAL read hardening, the native suite was additionally repeated on
iOS 26.4: 6 passed, 6 skipped, 0 failures. This is a repetition, not six additional
tests on top of the E04 total. E01/E02, the final iOS 27 pass, and Release include that
change.

Intermediate runs also passed 9 iOS 27 UI tests and, after adding cases, 21 iOS 27
native/UI tests with 2 skips, and 12 iOS 26.4 native/UI tests with 11 skips. They are
not added to the final runs nor presented as unique tests. Fixed during review:
stepwise saving, corrupted classification, source selection by name, a default
overriding an opt-out, loss of partial results, variable HRV cutoff, and empty
confirmation under limited reading.

The XXXL test initially detected a control outside the expected scrolling range. The
scope check was expanded, and visual inspection additionally detected narrow columns
with fragmented words. Rows now stack at accessibility sizes; the iOS 26.4 suite and
its final screenshots verified scope and reading. The repository also blocks a load
with an inaccessible WAL, without losing it or classifying it as a new installation;
the synthetic POSIX test preserves its bytes.

A full internal disk interrupted a build and intermediate UI runs (including a blocked
save). Those runs are not counted as passed. Only this work's temporary artifacts were
moved to the external volume, and the final checks were repeated with available space.

## P01–P24 correspondence

All cases in this table refer to candidate 0.3.0 (7) and the E01–E07 environment.
"Partial" means useful evidence but full acceptance pending.

| ID | Result and evidence | Omissions / pending |
| --- | --- | --- |
| P01 | Partial: simulated login → one-time setup, E02/E03 | Real WHOOP login |
| P02 | Partial: MFA/credentials with simulated transport, UI cancellation/reopen, E02/E03/E04 | Real MFA and reopen on device |
| P03 | Partial: simulated selection/authorization, single save and seven days, E02/E03 | Full walkthrough with base native permissions and real WHOOP |
| P04 | Partial: opt-out, save, relaunch and reopen reflect disabled HRV, E02/E03 | Real base sync after opt-out |
| P05 | Partial: iOS 26.4 configures base and explains RMSSD unavailable, E04 | Real older device |
| P06 | Partial: denied HRV preserves base request and allows continuing, E02/E03 | Denial in Apple's native dialog |
| P07 | Partial: unknown/limited, prevalent boundary and unobserved source rejected, E01/E02/E03 | New native read denied/limited profiles and physical revocation |
| P08 | Partial: empty preflight blocks before writing and result remains pending, E02 | Empty physical library, retry UI with ambiguous real permissions |
| P09 | Partial: exact observed bundle, native reconciliation/exporter and ownership, E01/E02 | Real WHOOP export and on-device ambiguity |
| P10 | Partial: one atomic commit point, write failure/rollback/reload, E02/E03/E04 | Physical power/storage cutoff |
| P11 | Partial: network/401/429, Retry-After and cancellation with doubles, E01/E02 | Real failures after save on iPhone |
| P12 | Partial: FC failure preserves confirmed sleep; differentiated results, E01/E02 | Partially completed result with real HealthKit/WHOOP |
| P13 | Partial: active HRV status without marker, incremental UI and binary update preserve progress, E02/E03/E06 | Real session, Health metadata and physical update |
| P14 | Partial: opt-out, old scheme and account safeguard, E02/E03/E04/E06 | Physical update with pending account |
| P15 | Partial: non-mutating authorization/cancellation, functional state and preserved bytes, E02/E03 | Real Apple dialog followed by physical cancellation/relaunch |
| P16 | Partial: save preserves date/cursor/cutoff/checkpoints and does not trigger sync, E02 | Reconfiguration on a real device |
| P17 | Partial: repeating history does not duplicate and preserves daily checkpoints/resolution, E01/E02 | Large real history and metadata before/after |
| P18 | Partial: durable resumption between windows and HRV phase; same cutoff, E01/E02 | Process termination/phone during real writes |
| P19 | Partial: expanding reopens enumeration preserving pending items; reducing does not trim, E02 | Real volume and limited permissions during expansion |
| P20 | Partial: serial runtime, double-save rejected, cancellation and wrong account blocked, E01/E02 | Concurrent Shortcut with physical import and disconnect between writes |
| P21 | Partial: App Intent identity retained, non-mutating preflight for new/existing installations, E02/E05 | Execution of existing Shortcut and protection with locked iPhone |
| P22 | Partial: ES/EN, accessible labels/controls and XXXL, E03/E04/E07 | Complete VoiceOver walkthrough and XXXL at all physical stages |
| P23 | Automated: E01/E02 and native/UI suites; explicit omissions | No physical test replaced by mocks |
| P24 | Partial: E05 identity/signature and E06 binary update with synthetic state | Package installed as an update and physical before/after comparison |

## Reproduction and physical acceptance

### Additional review of the already published candidate

The 0.3 implementation was already at commit `4627e6c` when this review began. A
cross-cutting result criterion was corrected: the absence of global errors is not
enough to present an operation as complete if there are unverified phases, pending
reads, or pending recoveries. Panel, Activity, and the operation's persisted state now
use the same criterion; confirmed samples continue to be shown separately. A response
without data keeps its specific label, without claiming that the entire history was
imported.

The core repetition passed 86 tests, zero failures, including a regression of pending
HRV without global errors. The service checks were repeated with the new criterion.
The read boundaries test also verifies that the operation's persisted state is partial.
The previous E01–E07 results belong to their original execution; they do not by
themselves accredit this adjustment or a new physical installation.

Additional repetition with stable sources, Xcode 27 and synthetic fixtures:

| Layer | Adjustment result | Limits |
| --- | --- | --- |
| Core | 86 passed, 0 failures | Does not replace real HealthKit/WHOOP |
| Services and capabilities | `verify_local.sh` fully passed | Includes partial-state regression under limited reading |
| iOS 27 native/UI | 21 passed, 2 skipped, 0 failures | Existing QA profile; physical protection and older-iOS-exclusive case omissions |
| iOS 26.4 native/UI | 12 passed, 11 skipped, 0 failures | RMSSD/iOS 27 cases unavailable; physical protection omitted |
| Release iPhone 0.3.0 (7) | Build and strict signing passed | Same identity/team; fixtures absent from binary; not installed |

The first additional simulator attempt failed due to overlapping with editing and
using a previous core module. It was repeated with stable sources, and only that final
pass counts as passed. Xcode warnings about building with zero exit code and debugger
version did not produce failures in the final pass; both xcresult confirm zero failures
and no runtime warnings. This adjustment reinforces P07/P12 and their public results;
it does not close their physical acceptance omissions nor repeat the E06 binary
comparison.

Core/services commands above. For simulators, follow `TESTING.md` with the
`WHOOPHealthSync` scheme, SDK 27, isolated QA devices and
`DEBUG WHOOP_IOS27_SDK WHOOP_VALIDATION_BUILD`; record omissions. For Release, build
for the generic iOS destination and verify `codesign --verify --deep --strict`,
Info.plist, and absence of fixture identifiers/credentials in the Mach-O.

The E06 test compiled the base in a separate worktree and the candidate in another
DerivedData, installed without uninstalling, and compared the resolved store and WAL
from the current container after each installation. The system can change the physical
path of the container while preserving its data; a stale path was not compared.

Before accepting the physical delivery: keep a private copy of the state/metadata,
verify the same signature and version, install as an update **without uninstalling**,
and check the before/after state. The user performs the real WHOOP tests on their
iPhone. No fixtures will be introduced there. Revocation, empty library, WHOOP
coexistence, large history, interruptions, Shortcuts, and lock must be checked. Until
then, P01–P22/P24 are not declared exhaustively accepted.

Logs, xcresult, screenshots, binaries, signing profiles, device paths/identifiers, and
state copies remain outside Git. Only code and this summary without personal data is
published.
