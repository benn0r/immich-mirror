#!/usr/bin/env bash
set -euo pipefail
if [[ -f .env ]]; then
  set -a
  source .env
  set +a
fi
: "${IOS_DEVICE_ID:?Set IOS_DEVICE_ID to the target device identifier}"
npm run ios:release
xcrun devicectl device install app --device "$IOS_DEVICE_ID" ".build/DerivedData/Build/Products/Release-iphoneos/ImmichMirror.app"
xcrun devicectl device process launch --terminate-existing --device "$IOS_DEVICE_ID" ch.benn0r.immichmirror
