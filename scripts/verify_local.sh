#!/usr/bin/env bash
set -euo pipefail

cd "$(dirname "$0")/.."

host_sdk="$(xcrun --sdk macosx --show-sdk-path)"
host_target="$(uname -m)-apple-macosx14.0"
xcodebuild -version
xcrun swiftc -version
echo "Host SDK: $host_sdk; target: $host_target"
swift build --build-system native --jobs 2

build_path="$(swift build --build-system native --show-bin-path)"
swiftc -sdk "$host_sdk" -target "$host_target" -typecheck -parse-as-library \
  -I "$build_path/Modules" \
  $(find iOS/WHOOPHealthSync -name '*.swift' | sort)

smoke_dir="$(mktemp -d "${TMPDIR:-/tmp}/whoop-smoke.XXXXXX")"
trap 'rm -rf "$smoke_dir"' EXIT
core_objects=("$build_path"/WHOOPHealthSyncCore.build/*.swift.o)

run_smoke() {
  local name="$1"
  shift
  swiftc -sdk "$host_sdk" -target "$host_target" \
    -I "$build_path/Modules" \
    "$@" \
    -o "$smoke_dir/$name"
  "$smoke_dir/$name"
}

run_smoke auth \
  iOS/WHOOPHealthSync/AppLog.swift \
  iOS/WHOOPHealthSync/Services/KeychainTokenStore.swift \
  iOS/WHOOPHealthSync/Services/WhoopAuthService.swift \
  scripts/auth_smoke_check.swift

run_smoke api \
  iOS/WHOOPHealthSync/AppLog.swift \
  iOS/WHOOPHealthSync/Services/KeychainTokenStore.swift \
  iOS/WHOOPHealthSync/Services/WhoopAuthService.swift \
  iOS/WHOOPHealthSync/Services/WhoopAPIClient.swift \
  scripts/whoop_api_smoke_check.swift \
  "${core_objects[@]}"

run_smoke repository \
  iOS/WHOOPHealthSync/AppLog.swift \
  iOS/WHOOPHealthSync/Persistence/SyncModels.swift \
  iOS/WHOOPHealthSync/Persistence/SyncRepository.swift \
  scripts/repository_smoke_check.swift \
  "${core_objects[@]}"

run_smoke sync-engine \
  iOS/WHOOPHealthSync/AppLog.swift \
  iOS/WHOOPHealthSync/Persistence/SyncModels.swift \
  iOS/WHOOPHealthSync/Persistence/SyncRepository.swift \
  iOS/WHOOPHealthSync/Services/MetadataKeys.swift \
  iOS/WHOOPHealthSync/Services/HealthKitSampleFactory.swift \
  iOS/WHOOPHealthSync/Services/HealthKitService.swift \
  iOS/WHOOPHealthSync/Services/KeychainTokenStore.swift \
  iOS/WHOOPHealthSync/Services/WhoopAuthService.swift \
  iOS/WHOOPHealthSync/Services/WhoopAPIClient.swift \
  iOS/WHOOPHealthSync/Services/SyncEngine.swift \
  scripts/sync_engine_smoke_check.swift \
  "${core_objects[@]}"

run_smoke view-model \
  iOS/WHOOPHealthSync/AppLog.swift \
  iOS/WHOOPHealthSync/Persistence/SyncModels.swift \
  iOS/WHOOPHealthSync/Persistence/SyncRepository.swift \
  iOS/WHOOPHealthSync/Services/MetadataKeys.swift \
  iOS/WHOOPHealthSync/Services/HealthKitSampleFactory.swift \
  iOS/WHOOPHealthSync/Services/HealthKitService.swift \
  iOS/WHOOPHealthSync/Services/KeychainTokenStore.swift \
  iOS/WHOOPHealthSync/Services/WhoopAuthService.swift \
  iOS/WHOOPHealthSync/Services/WhoopAPIClient.swift \
  iOS/WHOOPHealthSync/Services/SyncEngine.swift \
  iOS/WHOOPHealthSync/Services/HealthKitRecoveryAdapter.swift \
  iOS/WHOOPHealthSync/Services/LiveSyncRuntime.swift \
  iOS/WHOOPHealthSync/Services/SyncCoordinator.swift \
  iOS/WHOOPHealthSync/UI/SyncViewModel.swift \
  scripts/view_model_smoke_check.swift \
  "${core_objects[@]}"

run_smoke healthkit-factory \
  iOS/WHOOPHealthSync/AppLog.swift \
  iOS/WHOOPHealthSync/Services/KeychainTokenStore.swift \
  iOS/WHOOPHealthSync/Services/WhoopAuthService.swift \
  iOS/WHOOPHealthSync/Services/WhoopAPIClient.swift \
  iOS/WHOOPHealthSync/Services/MetadataKeys.swift \
  iOS/WHOOPHealthSync/Services/HealthKitSampleFactory.swift \
  iOS/WHOOPHealthSync/Services/HealthKitService.swift \
  scripts/healthkit_factory_smoke_check.swift \
  "${core_objects[@]}"

run_smoke app-intents \
  iOS/WHOOPHealthSync/AppLog.swift \
  iOS/WHOOPHealthSync/Persistence/SyncModels.swift \
  iOS/WHOOPHealthSync/Persistence/SyncRepository.swift \
  iOS/WHOOPHealthSync/Services/MetadataKeys.swift \
  iOS/WHOOPHealthSync/Services/HealthKitSampleFactory.swift \
  iOS/WHOOPHealthSync/Services/HealthKitService.swift \
  iOS/WHOOPHealthSync/Services/KeychainTokenStore.swift \
  iOS/WHOOPHealthSync/Services/WhoopAuthService.swift \
  iOS/WHOOPHealthSync/Services/WhoopAPIClient.swift \
  iOS/WHOOPHealthSync/Services/SyncEngine.swift \
  iOS/WHOOPHealthSync/Services/HealthKitRecoveryAdapter.swift \
  iOS/WHOOPHealthSync/Services/LiveSyncRuntime.swift \
  iOS/WHOOPHealthSync/Services/SyncCoordinator.swift \
  iOS/WHOOPHealthSync/Intents/SynchronizeWhoopIntent.swift \
  scripts/app_intents_smoke_check.swift \
  "${core_objects[@]}"

run_smoke sync-coordinator \
  iOS/WHOOPHealthSync/AppLog.swift \
  iOS/WHOOPHealthSync/Services/SyncCoordinator.swift \
  scripts/sync_coordinator_smoke_check.swift \
  "${core_objects[@]}"

plutil -lint \
  iOS/WHOOPHealthSync/Info.plist \
  iOS/WHOOPHealthSync/PrivacyInfo.xcprivacy \
  iOS/WHOOPHealthSync/WHOOPHealthSync.entitlements \
  iOS/WHOOPHealthSync.xcodeproj/project.pbxproj

strings_dir="$(mktemp -d "/tmp/health-data-bridge-strings.XXXXXX")"
trap 'rm -rf "$smoke_dir" "$strings_dir"' EXIT
for lproj_dir in iOS/WHOOPHealthSync/*.lproj; do
  mkdir -p "$strings_dir/$(basename "$lproj_dir" .lproj)"
done
for strings_file in iOS/WHOOPHealthSync/*.lproj/*.strings; do
  lang_dir="$strings_dir/$(basename "$(dirname "$strings_file")" .lproj)"
  plutil -convert xml1 -o - "$strings_file" | sed -n 's/^[[:space:]]*<key>\(.*\)<\/key>$/\1/p' | LC_ALL=C sort -u > "$lang_dir/$(basename "$strings_file")"
done
strings_drift=0
for strings_name in $(find "$strings_dir" -type f -name '*.strings' -exec basename {} \; | sort -u); do
  cat "$strings_dir"/*/"$strings_name" 2>/dev/null | LC_ALL=C sort -u > "$strings_dir/all.keys" || true
  for lang_dir in "$strings_dir"/*/; do
    lang="$(basename "$lang_dir")"
    if [[ ! -f "$lang_dir$strings_name" ]]; then
      echo "$strings_name: file missing for $lang" >&2
      strings_drift=1
      continue
    fi
    missing_keys="$(LC_ALL=C comm -23 "$strings_dir/all.keys" "$lang_dir$strings_name")"
    if [[ -n "$missing_keys" ]]; then
      printf '%s\n' "$missing_keys" | sed "s/^/$strings_name: $lang missing key: /" >&2
      strings_drift=1
    fi
  done
done
if [[ "$strings_drift" != 0 ]]; then
  exit 1
fi
echo "Localization key parity passed"

healthkit_entitlement="$(/usr/libexec/PlistBuddy -c 'Print :com.apple.developer.healthkit' iOS/WHOOPHealthSync/WHOOPHealthSync.entitlements)"
if [[ "$healthkit_entitlement" != "true" ]]; then
  echo "Expected HealthKit entitlement to be true." >&2
  exit 1
fi
entitlement_keys="$(/usr/libexec/PlistBuddy -c 'Print' iOS/WHOOPHealthSync/WHOOPHealthSync.entitlements | sed -n 's/^[[:space:]]*\([^=][^=]*\)[[:space:]]*=.*/\1/p' | xargs)"
if [[ "$entitlement_keys" != "com.apple.developer.healthkit" ]]; then
  echo "Entitlements must be limited to HealthKit for the MVP." >&2
  echo "$entitlement_keys" >&2
  exit 1
fi

health_share_usage="$(/usr/libexec/PlistBuddy -c 'Print :NSHealthShareUsageDescription' iOS/WHOOPHealthSync/Info.plist)"
if [[ -z "$health_share_usage" ]]; then
  echo "Missing NSHealthShareUsageDescription." >&2
  exit 1
fi

health_update_usage="$(/usr/libexec/PlistBuddy -c 'Print :NSHealthUpdateUsageDescription' iOS/WHOOPHealthSync/Info.plist)"
if [[ -z "$health_update_usage" ]]; then
  echo "Missing NSHealthUpdateUsageDescription." >&2
  exit 1
fi

if /usr/libexec/PlistBuddy -c 'Print :UIBackgroundModes' iOS/WHOOPHealthSync/Info.plist >/dev/null 2>&1; then
  echo "Info.plist must not declare UIBackgroundModes; MVP sync is manual only." >&2
  exit 1
fi

for forbidden_usage_key in \
  NSBluetoothAlwaysUsageDescription \
  NSCalendarsUsageDescription \
  NSCameraUsageDescription \
  NSContactsUsageDescription \
  NSLocationAlwaysAndWhenInUseUsageDescription \
  NSLocationWhenInUseUsageDescription \
  NSMicrophoneUsageDescription \
  NSMotionUsageDescription \
  NSPhotoLibraryUsageDescription \
  NSRemindersUsageDescription; do
  if /usr/libexec/PlistBuddy -c "Print :$forbidden_usage_key" iOS/WHOOPHealthSync/Info.plist >/dev/null 2>&1; then
    echo "Info.plist declares unnecessary permission key: $forbidden_usage_key" >&2
    exit 1
  fi
done

privacy_tracking="$(/usr/libexec/PlistBuddy -c 'Print :NSPrivacyTracking' iOS/WHOOPHealthSync/PrivacyInfo.xcprivacy)"
if [[ "$privacy_tracking" != "false" ]]; then
  echo "Privacy manifest should declare no tracking." >&2
  exit 1
fi

if ! /usr/libexec/PlistBuddy -c 'Print :NSPrivacyCollectedDataTypes' iOS/WHOOPHealthSync/PrivacyInfo.xcprivacy >/dev/null; then
  echo "Privacy manifest should declare collected data types." >&2
  exit 1
fi
if ! /usr/libexec/PlistBuddy -c 'Print :NSPrivacyAccessedAPITypes' iOS/WHOOPHealthSync/PrivacyInfo.xcprivacy >/dev/null; then
  echo "Privacy manifest should declare accessed API types." >&2
  exit 1
fi

project_file="iOS/WHOOPHealthSync.xcodeproj/project.pbxproj"
if ! grep -q 'CODE_SIGN_ENTITLEMENTS = WHOOPHealthSync/WHOOPHealthSync.entitlements;' "$project_file"; then
  echo "Target is not wired to WHOOPHealthSync.entitlements." >&2
  exit 1
fi
if ! grep -q 'PRODUCT_BUNDLE_IDENTIFIER = org.shpaq.WHOOPHealthSync;' "$project_file"; then
  echo "Unexpected or missing bundle identifier." >&2
  exit 1
fi
if ! grep -q 'TARGETED_DEVICE_FAMILY = 1;' "$project_file"; then
  echo "Target should be configured for iPhone." >&2
  exit 1
fi
if ! grep -q 'PrivacyInfo.xcprivacy in Resources' "$project_file"; then
  echo "PrivacyInfo.xcprivacy is not included in target resources." >&2
  exit 1
fi
if ! grep -q 'SynchronizeWhoopIntent.swift in Sources' "$project_file"; then
  echo "App Intent is not included in target sources." >&2
  exit 1
fi
if ! grep -q 'LiveSyncRuntime.swift in Sources' "$project_file"; then
  echo "Shared live sync runtime is not included in target sources." >&2
  exit 1
fi
if ! grep -q 'SyncCoordinator.swift in Sources' "$project_file"; then
  echo "Sync coordinator is not included in target sources." >&2
  exit 1
fi

echo "iOS project capability lint passed"

# Keep build artifacts for reproducible subsequent iOS builds.
