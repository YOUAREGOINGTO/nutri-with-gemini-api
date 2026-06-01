#!/usr/bin/env bash
set -euo pipefail

cd "$(dirname "$0")/.."

if ! command -v flutter >/dev/null 2>&1; then
  echo "Flutter is not installed or is not on PATH." >&2
  exit 1
fi

flutter pub get

if command -v pod >/dev/null 2>&1; then
  (cd ios && pod install)
else
  echo "CocoaPods is not installed or is not on PATH." >&2
  echo "Install it on macOS, then rerun this script." >&2
  exit 1
fi

flutter build ipa --release "$@"

echo "IPA output directory: build/ios/ipa"
