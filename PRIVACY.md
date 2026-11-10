# Privacy

HealthDataBridge is an experimental client-side iOS app. It does not run a project-operated account server or cloud health database, and contains no advertising or third-party analytics SDK.

## Data flow

The app connects directly to WHOOP services using the account you supply. You sign in on WHOOP's own web page inside the app, which uses a non-persistent web data store. The app does not read what you type there; it reads only the WHOOP session cookies to obtain tokens. Saved tokens are kept in Keychain using `WhenUnlockedThisDeviceOnly`. Apple Health permission requests cover sleep, heart rate and optionally recovery RMSSD. WHOOP and Apple independently operate their services under their own policies.

The app reads existing Apple Health samples for overlap/source checks and writes eligible missing records. Operational JSON state on the device includes checkpoints, reconciliation identifiers/fingerprints, recovery history progress, pending operations, recent events and run summaries. These records can contain sensitive information even when direct credentials are omitted.

Diagnostics are designed to redact credentials and email addresses. A recovery comparison view can display health values locally. Redaction is not a reason to post complete logs publicly: inspect and minimize anything you share. This repository excludes local logs, personal diagnostic evidence and sync-store files.

## Control

Change Health permissions in Apple's Health settings. Disable optional recovery HRV in the app to stop that feature. Disconnecting WHOOP ends the connected session; it does not remove samples already imported into Apple Health. Deleting the app is not equivalent to deleting its previously written Health data. Manage those records through Apple Health.

Read visibility is limited by HealthKit behavior. Empty results cannot prove that all read permissions are granted. A personal confirmation of full access can become stale if permissions are subsequently changed; revisit recovery configuration after permission changes.

Do not submit personal health exports, passwords, tokens, emails or device identifiers in GitHub issues.
