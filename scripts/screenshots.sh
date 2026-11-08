#!/usr/bin/env bash
# Takes the App Store screenshots with fictional data (`-demo`) in the iOS simulator.
#   scripts/screenshots.sh                      → screenshots/appstore/ (iPhone 17 Pro, 1206×2622: App Store Connect's "iPhone with Dynamic Island" size)
#   LANGUAGE=fr LOCALE=fr_FR scripts/screenshots.sh   → screenshots/appstore/fr/
set -euo pipefail
cd "$(dirname "$0")/.."

simulator="${SIMULATOR:-iPhone 17 Pro}"
language="${LANGUAGE:-en}"
locale="${LOCALE:-en_US}"
if [[ "$language" == en ]]; then out="${OUT:-screenshots/appstore}"; else out="${OUT:-screenshots/appstore/$language}"; fi
language_args=(-AppleLanguages "($language)" -AppleLocale "$locale")
width="${WIDTH:-}"
prefix="${PREFIX:-}"
bundle_id=ch.benn0r.immichmirror

# A dedicated simulator, so other apps or sessions using the regular one can't get in the way.
device_name="Photo Mirror Screenshots ($simulator)"
find_device() {
  xcrun simctl list devices available -j | python3 -c "
import json, sys
name = sys.argv[1]
for runtime, devices in json.load(sys.stdin)['devices'].items():
    for d in devices:
        if d['name'] == name and 'iOS' in runtime:
            print(d['udid']); sys.exit()" "$1"
}
udid=$(find_device "$device_name")
if [[ -z "$udid" ]]; then
  template=$(find_device "$simulator")
  [[ -n "$template" ]] || { echo "No available simulator named $simulator" >&2; exit 1; }
  type=$(xcrun simctl list devices -j | python3 -c "
import json, sys
for devices in json.load(sys.stdin)['devices'].values():
    for d in devices:
        if d['udid'] == sys.argv[1]: print(d['deviceTypeIdentifier'])" "$template")
  udid=$(xcrun simctl create "$device_name" "$type")
fi

xcrun simctl boot "$udid" 2>/dev/null || true
xcrun simctl bootstatus "$udid" -b >/dev/null

npm run -s project:generate >/dev/null
xcodebuild build -project ImmichMirror.xcodeproj -scheme ImmichMirror -configuration Debug \
  -destination "id=$udid" -derivedDataPath .build/DerivedData -quiet
xcrun simctl install "$udid" .build/DerivedData/Build/Products/Debug-iphonesimulator/ImmichMirror.app

xcrun simctl ui "$udid" appearance light
xcrun simctl status_bar "$udid" override --time "9:41" --batteryState charged \
  --batteryLevel 100 --wifiBars 3 --cellularMode active --cellularBars 4
trap 'xcrun simctl status_bar "$udid" clear' EXIT

mkdir -p "$out"
shoot() { # file, extra launch arguments…
  local file=$1
  shift
  xcrun simctl launch --terminate-running-process "$udid" "$bundle_id" -demo ${language_args[@]+"${language_args[@]}"} "$@" >/dev/null
  sleep 7
  xcrun simctl io "$udid" screenshot "$out/$prefix$file.png" >/dev/null 2>&1
  if [[ -n "$width" ]]; then sips --resampleWidth "$width" "$out/$prefix$file.png" >/dev/null; fi
  echo "$out/$prefix$file.png"
}

shoot home
shoot dry-run -demo-screen dry-run
shoot report -demo-screen report
shoot settings -demo-screen settings
