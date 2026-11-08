#!/usr/bin/env bash
# Archives a Release build and exports a development-signed IPA (installs on the team's registered devices)
# to .build/export/ImmichMirror.ipa. Automatic signing; with ASC_KEY_ID, ASC_ISSUER_ID (and
# ASC_KEY_PATH) set, Xcode signs in with the App Store Connect API key instead of the Apple ID in
# Xcode's settings. MARKETING_VERSION and BUILD_NUMBER override the values in project.yml.
set -euo pipefail
cd "$(dirname "$0")/.."
if [[ -f .env ]]; then
  set -a
  source .env
  set +a
fi
: "${IOS_DEVELOPMENT_TEAM:?Set IOS_DEVELOPMENT_TEAM}"
npm run -s project:generate >/dev/null
rm -rf .build/ImmichMirror.xcarchive .build/export

auth=(-allowProvisioningUpdates)
if [[ -n "${ASC_KEY_ID:-}" && -n "${ASC_ISSUER_ID:-}" ]]; then
  key="${ASC_KEY_PATH:-$HOME/.appstoreconnect/private_keys/AuthKey_${ASC_KEY_ID}.p8}"
  auth+=(-authenticationKeyPath "$key" -authenticationKeyID "$ASC_KEY_ID" -authenticationKeyIssuerID "$ASC_ISSUER_ID")
fi
overrides=()
[[ -n "${MARKETING_VERSION:-}" ]] && overrides+=(MARKETING_VERSION="$MARKETING_VERSION")
[[ -n "${BUILD_NUMBER:-}" ]] && overrides+=(CURRENT_PROJECT_VERSION="$BUILD_NUMBER")

sed "s/__TEAM__/$IOS_DEVELOPMENT_TEAM/" scripts/ExportOptions.plist > .build/ExportOptions.plist
xcodebuild archive -project ImmichMirror.xcodeproj -scheme ImmichMirror -configuration Release \
  -destination 'generic/platform=iOS' -archivePath .build/ImmichMirror.xcarchive \
  -derivedDataPath .build/DerivedData "${auth[@]}" -quiet ${overrides[@]+"${overrides[@]}"}
xcodebuild -exportArchive -archivePath .build/ImmichMirror.xcarchive \
  -exportOptionsPlist .build/ExportOptions.plist -exportPath .build/export "${auth[@]}"
ls -la .build/export/ImmichMirror.ipa
