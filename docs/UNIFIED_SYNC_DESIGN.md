# Unified synchronization and update continuity

## User experience

WHOOP is connected once. A fresh installation then presents Configure sync: sleep,
heart rate and optional, system-compatible recovery HRV. One HealthKit request
covers the selected types. The HRV read/coexistence checks remain explicit because
HealthKit does not expose denied read authorization. Users can continue without
HRV if it is unavailable, denied or already exported by WHOOP.

Save and sync starts the first seven-day synchronization. There is no historical
date question during setup. Thereafter the dashboard, manual button and existing
Sync WHOOP App Intent use the same recent synchronization pipeline. The dashboard
shows all three data types and a common result. Configure sync remains available
in Options; saving settings on an existing installation does not trigger an import.
There is no separate recovery-HRV setup or import action: HRV is configured in
Configure sync and imported by the common sync and history actions.

## Existing installations

Setup is already complete when the repository contains live checkpoints, configured
recovery or legacy progress requiring the existing account-binding safeguard. Only
new installations need the new syncSetupCompleted record (also remembers HRV opt-out
before a successful first sync). No forced onboarding or speculative account binding
is introduced. Keychain identifiers, the app container, sample IDs, metadata and the
existing App Intent implementation are unchanged.

Authorization/inspection is non-mutating. Cancelling settings retains enabled state,
manual read confirmation, exporter identity, history start, cutoff, cursor, records,
pending items/WAL and recent discovery. Saving settings reuses the exact saved HRV
start date rather than applying the seven-day new-user default to existing users.

The app's own HealthKit ownership bundle is derived from the running app identity.
The existing bundle yields the same ownership identity; a new user's bundle no longer
requires hand-editing recovery source code. No official WHOOP source is invented.

## Explicit historical import

Options offers one Import an earlier period action. The selected start and a fixed
cutoff are persisted using the existing extensible state-record store; no schema or
file identity changes are needed. Sleep and heart rate are traversed in seven-day
windows (heart rate retains its smaller internal chunks), then configured HRV history
is reconciled and recent HRV is discovered. Existing wider HRV history is never shrunk.
Only an explicitly earlier requested period reopens HRV enumeration; existing records,
pending operations, confirmations and recent discovery are retained.

History's cursor/active phase is independent of live sleep/heart-rate checkpoints and
resolution. A historical window never advances or clears live checkpoints/deferred
work. Failed, partial or cancelled windows are retried idempotently; the next date is
committed only after both data pipelines finish without errors. The active phase is
retained if interruption occurs after those windows but before HRV completes. Resume
does not change the original cutoff or replay confirmed windows. The existing HRV
cursor/WAL remains authoritative for its own progress.

The read-visibility check for a historical window looks at the 30 days before the
run starts, not before the window end, so a window older than the first Health data
is not blocked by it. Recovery HRV counts as settled when its status is completed,
limited, no data, skipped for an external exporter, paused for native export,
disabled or unavailable before iOS 27, and no item is pending or access-deferred.
The engine, the history importer and the run summary use this one rule, so a settled
HRV phase lets the history import finish. Options shows Stop import only while a
history import runs; cancelling an ordinary sync records no error.

Manual synchronization and Shortcuts do not resume this separate history traversal.
The existing recent correction windows, incremental overlap and recovery pending-ID
reconciliation remain intact. There is no autonomous background scheduler.

## Acceptance evidence

This design was implemented in 0.3.1 (7), which VALIDATION_0.3.md describes as
0.3.0 (7), and revised in candidate 0.4.0 (8). Neither is a claim of a newly
installed or physically accepted release. The normative September 15 specification
takes precedence over the initial local design. See VALIDATION_0.3.md and
VALIDATION_0.4.md for actual results.

Repository classification is gated by ensureUsable; inaccessible/corrupt data blocks
setup rather than becoming a usable empty installation. Initial account binding,
HRV preferences and syncSetupCompleted are committed in one protected atomic write,
with existing snapshot rollback. The runtime revalidates the current account,
base write permissions, HRV write access, actually observed source identity and native
read boundaries immediately before saving. Temporary request results distinguish
base write denial from HRV denial and unknown/limited reading. Dropping HRV retains
the already-requested base types. No source is automatically identified by name.

Recent runs validate permissions without reopening setup or permissions sheets.
Manual sync still reconciles legacy access-deferred windows; these are not the
separate explicit-history task. When read access covers only part of a deferred
window, manual sync reads that part once and shrinks the window to the range still
behind the boundary. Shortcuts retain their existing deferred-work policy.
Results distinguish confirmed writes, existing samples, no received data, unchecked
phases and pending access. Global failures retain the runtime's confirmed partial
summary. Empty historical responses with limited reading cannot confirm a window.
The history phase and fixed cutoff are durable; HRV recent discovery uses that same
cutoff on resume and never rewinds its daily discovery checkpoint.

Service checks exercise fresh setup, seven-day HRV default, combined authorization,
failed authorization, HRV opt-out, persistent setup decisions, unchanged existing
recovery state, historical execution, cancellation, exact live-checkpoint/resolution
preservation, replay idempotency, limited-access deferral, durable chunk resume and
explicit HRV scope expansion. Existing auth, repository, engine and App Intent checks
remain part of verify_local.sh.

Isolated simulator UI fixtures exercise Spanish combined setup with read/coexistence
checks, a common historical-date sheet, existing-installation daily sync and relaunch,
and HRV opt-out/relaunch, alongside existing language, accessibility and sign-in tests.
They contain no real WHOOP transport or HealthKit writes and cannot run on physical
devices. Native HealthKit tests remain a separate layer. This is not a claim of
exhaustive acceptance for every real account or permission configuration.
