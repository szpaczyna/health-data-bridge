#!/usr/bin/env bash
# Builds WHOOPHealthSync and installs it on a physical iPhone with devicectl.
set -euo pipefail

cd "$(dirname "$0")/.."

usage() {
  cat <<'EOF'
Usage: scripts/install_on_device.sh [-c Debug|Release] [--launch] [device]

device   Device name, UDID or devicectl identifier. Defaults to the only paired
         physical iPhone.
-c       Build configuration (default: Debug).
--launch Start the app after installing it.
EOF
}

configuration="Debug"
launch=false
device=""
while (($#)); do
  case "$1" in
    -c|--configuration) configuration="${2:?missing configuration}"; shift 2 ;;
    --launch) launch=true; shift ;;
    -h|--help) usage; exit 0 ;;
    -*) usage >&2; exit 2 ;;
    *) device="$1"; shift ;;
  esac
done

work="$(mktemp -d "/tmp/whoop-device-install.XXXXXX")"
trap 'rm -rf "$work"' EXIT

xcrun devicectl list devices --json-output "$work/devices.json" >/dev/null
matches="$(jq -r --arg d "$device" '
  .result.devices[]
  | select(.hardwareProperties.reality == "physical" and .hardwareProperties.platform == "iOS" and .connectionProperties.pairingState == "paired")
  | select($d == "" or .deviceProperties.name == $d or .hardwareProperties.udid == $d or .identifier == $d)
  | "\(.identifier)\t\(.deviceProperties.name)"' "$work/devices.json")"

if [[ -z "$matches" ]]; then
  echo "No paired physical iPhone matches '${device:-<any>}'. Paired devices:" >&2
  jq -r '.result.devices[] | select(.connectionProperties.pairingState == "paired") | "  \(.deviceProperties.name) (\(.hardwareProperties.reality))"' "$work/devices.json" >&2
  exit 1
fi
if [[ "$(printf '%s\n' "$matches" | wc -l)" -gt 1 ]]; then
  echo "More than one iPhone matches; pass a device name:" >&2
  printf '%s\n' "$matches" | cut -f2 | sed 's/^/  /' >&2
  exit 1
fi
device_id="$(printf '%s' "$matches" | cut -f1)"
device_name="$(printf '%s' "$matches" | cut -f2)"

if ! xcrun devicectl device info details --device "$device_id" --quiet --timeout 20 >/dev/null 2>&1; then
  echo "Cannot reach $device_name. Unlock it and keep it on the same Wi-Fi as this Mac, or connect a cable." >&2
  exit 1
fi

derived_data="build/DerivedData-device"
echo "Building $configuration for $device_name..."
xcodebuild -quiet \
  -project iOS/WHOOPHealthSync.xcodeproj \
  -scheme WHOOPHealthSync \
  -configuration "$configuration" \
  -destination 'generic/platform=iOS' \
  -derivedDataPath "$derived_data" \
  -allowProvisioningUpdates \
  build

app="$derived_data/Build/Products/$configuration-iphoneos/WHOOPHealthSync.app"
bundle_id="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' "$app/Info.plist")"
version="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$app/Info.plist")"
build="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleVersion' "$app/Info.plist")"

echo "Installing $bundle_id $version ($build) on $device_name..."
xcrun devicectl device install app --device "$device_id" "$app"

if [[ "$launch" == true ]]; then
  xcrun devicectl device process launch --device "$device_id" "$bundle_id"
fi
