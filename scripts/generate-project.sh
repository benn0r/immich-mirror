#!/usr/bin/env bash
set -euo pipefail
if [[ -f .env ]]; then
  set -a
  source .env
  set +a
fi
export IOS_DEVELOPMENT_TEAM="${IOS_DEVELOPMENT_TEAM:-}"
if ! command -v xcodegen >/dev/null 2>&1; then
  echo "XcodeGen is required. Install it with: brew install xcodegen" >&2
  exit 1
fi
xcodegen generate --spec project.yml
