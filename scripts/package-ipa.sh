#!/usr/bin/env bash
# Archives a Release build and exports a development-signed IPA (installs on the team's registered devices)
# to .build/export/ImmichMirror.ipa, or with UPLOAD=1 signs it for the App Store and uploads it to
# App Store Connect (`npm run upload`; set BUILD_NUMBER, e.g. from `npm run appstore next-build`). Automatic signing; with ASC_KEY_ID, ASC_ISSUER_ID and the key
# (ASC_KEY_P8 contents, or ASC_KEY_PATH) set, Xcode signs in with the App Store Connect API key instead
# of the Apple ID in Xcode's settings. MARKETING_VERSION and BUILD_NUMBER override project.yml.
#
# With OP_ENVIRONMENT_ID set, the secrets come from that 1Password Environment (`op run --environment`):
# locally through the 1Password app, in CI through OP_SERVICE_ACCOUNT_TOKEN.
set -euo pipefail
cd "$(dirname "$0")/.."
if [[ -f .env ]]; then
  set -a
  source .env
  set +a
fi
if [[ -n "${OP_ENVIRONMENT_ID:-}" && -z "${IMMICH_MIRROR_OP_LOADED:-}" ]]; then
  command -v op >/dev/null || { echo "1Password CLI (op) 2.41+ is required: brew install 1password-cli" >&2; exit 1; }
  echo "Loading signing secrets from 1Password Environment $OP_ENVIRONMENT_ID ($(op --version))"
  exec op run --environment "$OP_ENVIRONMENT_ID" -- env IMMICH_MIRROR_OP_LOADED=1 bash "$0" "$@"
fi
if [[ -z "${IOS_DEVELOPMENT_TEAM:-}" ]]; then
  if [[ -n "${IMMICH_MIRROR_OP_LOADED:-}" ]]; then
    echo "1Password Environment $OP_ENVIRONMENT_ID was loaded but has no IOS_DEVELOPMENT_TEAM." >&2
    echo "Variables it provided: $(env | grep -oE '^(IOS_DEVELOPMENT_TEAM|ASC_[A-Z0-9_]+)=' | tr -d = | xargs)" >&2
  elif [[ -n "${CI:-}${GITEA_ACTIONS:-}" ]]; then
    echo "OP_ENVIRONMENT_ID is empty: set it in Gitea as a repository variable or secret." >&2
  else
    echo "Set IOS_DEVELOPMENT_TEAM in .env, or OP_ENVIRONMENT_ID to load it from 1Password." >&2
  fi
  exit 1
fi
npm run -s project:generate >/dev/null
rm -rf .build/ImmichMirror.xcarchive .build/export
mkdir -p .build

# A key passed as contents (1Password, CI) is written to a private temp file for the run only.
if [[ -n "${ASC_KEY_P8:-}" && -z "${ASC_KEY_PATH:-}" ]]; then
  key_dir="$(mktemp -d -t asc-key)"
  trap 'rm -rf "$key_dir"' EXIT
  ASC_KEY_PATH="$key_dir/AuthKey.p8"
  # Secret fields often mangle line breaks (pasted as spaces, literal \n, CRLF), so the key is rebuilt as
  # clean PEM from its base64 body. Also accepts base64 of the whole .p8 file.
  key="$ASC_KEY_P8"
  if [[ "$key" != *"BEGIN PRIVATE KEY"* ]]; then
    key="$(printf '%s' "$key" | tr -d ' \t\r\n' | base64 -D)"
  fi
  body="$(printf '%s' "$key" | sed -e 's/-----BEGIN PRIVATE KEY-----//' -e 's/-----END PRIVATE KEY-----//' \
    -e 's/\\n//g' | tr -d ' \t\r\n')"
  (umask 077 && { echo "-----BEGIN PRIVATE KEY-----"; printf '%s' "$body" | fold -w 64; echo; \
    echo "-----END PRIVATE KEY-----"; } > "$ASC_KEY_PATH")
  openssl pkey -in "$ASC_KEY_PATH" -noout 2>/dev/null || { echo "ASC_KEY_P8 is not a valid .p8 key" >&2; exit 1; }
fi

auth=(-allowProvisioningUpdates)
if [[ -n "${ASC_KEY_ID:-}" && -n "${ASC_ISSUER_ID:-}" ]]; then
  key="${ASC_KEY_PATH:-$HOME/.appstoreconnect/private_keys/AuthKey_${ASC_KEY_ID}.p8}"
  auth+=(-authenticationKeyPath "$key" -authenticationKeyID "$ASC_KEY_ID" -authenticationKeyIssuerID "$ASC_ISSUER_ID")
fi
overrides=()
[[ -n "${MARKETING_VERSION:-}" ]] && overrides+=(MARKETING_VERSION="$MARKETING_VERSION")
[[ -n "${BUILD_NUMBER:-}" ]] && overrides+=(CURRENT_PROJECT_VERSION="$BUILD_NUMBER")

options=scripts/ExportOptions.plist
[[ -n "${UPLOAD:-}" ]] && options=scripts/ExportOptions-AppStore.plist
sed "s/__TEAM__/$IOS_DEVELOPMENT_TEAM/" "$options" > .build/ExportOptions.plist
xcodebuild archive -project ImmichMirror.xcodeproj -scheme ImmichMirror -configuration Release \
  -destination 'generic/platform=iOS' -archivePath .build/ImmichMirror.xcarchive \
  -derivedDataPath .build/DerivedData "${auth[@]}" -quiet ${overrides[@]+"${overrides[@]}"}
xcodebuild -exportArchive -archivePath .build/ImmichMirror.xcarchive \
  -exportOptionsPlist .build/ExportOptions.plist -exportPath .build/export "${auth[@]}"
if [[ -n "${UPLOAD:-}" ]]; then
  echo "Uploaded to App Store Connect; it shows up under TestFlight once processed."
else
  ls -la .build/export/ImmichMirror.ipa
fi
