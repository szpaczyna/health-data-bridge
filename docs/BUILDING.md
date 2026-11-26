# Building and installation identity

Use Xcode 27 with the iOS 27 SDK for this branch. The app and test targets set the deployment target to iOS 27.0; RMSSD depends on native iOS 27 support. A build/test on an older runtime does not validate RMSSD functionality.

Open `iOS/WHOOPHealthSync.xcodeproj` and select its shared scheme. Select your own team in Signing & Capabilities, or pass `DEVELOPMENT_TEAM=YOUR_TEAM_ID` to `xcodebuild`. The checked-in team identifies the existing maintainer installation; it is not a credential and does not grant signing access.

## New users

Choose an available bundle identifier you control. The app target's `PRODUCT_BUNDLE_IDENTIFIER` is substituted into Info.plist, and recovery ownership uses that running bundle identity automatically. No recovery source-code edits are needed. Do not invent a WHOOP exporter bundle; the app selects an actually observed source when configured.

Example simulator build, without personal signing:

```sh
xcodebuild -project iOS/WHOOPHealthSync.xcodeproj \
  -scheme WHOOPHealthSync -destination 'generic/platform=iOS Simulator' \
  CODE_SIGNING_ALLOWED=NO -jobs 2 build
```

## Install on an iPhone from the command line

`scripts/install_on_device.sh` builds the app with `xcodebuild` and installs it on a paired iPhone with `devicectl`. It uses automatic signing with the team in the project, so the Mac needs that team's account in Xcode. The phone must be unlocked and reachable over a cable or the same Wi-Fi network.

```sh
scripts/install_on_device.sh                  # the only paired physical iPhone, Debug
scripts/install_on_device.sh "My iPhone"      # pick a device by name, UDID or identifier
scripts/install_on_device.sh -c Release --launch
```

Build output stays in `build/DerivedData-device`, which Git ignores, so repeated runs build incrementally.

## Existing installations

Keep the same bundle identifier and signing identity when updating an existing app. Do not uninstall first. Preserve the Keychain service/account strings, `WHOOPHealthSync` application-support directory, sync IDs and metadata namespaces. Changing the public/display name does not require changing these persistence identities. Existing Shortcuts use the retained App Intent implementation.

If you intentionally change identity, treat the result as a separate installation requiring a planned migration and fresh setup. Never assume its state or sample ownership carries over.

## Runtime installation

Install simulator runtimes through Xcode Settings → Platforms/Components, or Apple's documented Xcode tools. The private local SDK/runtime repair helper used during development is not part of this repository. No signing certificates or provisioning profiles are included.
