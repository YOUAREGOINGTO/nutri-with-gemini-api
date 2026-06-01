#!/usr/bin/env bash
set -euo pipefail

cd "$(dirname "$0")/.."

app_path="build/ios/iphoneos/Runner.app"
ipa_dir="build/ios/ipa-unsigned"
ipa_name="nutrinutri-ios-unsigned.ipa"

if [ ! -d "$app_path" ]; then
  echo "Could not find $app_path. Run flutter build ios --release --no-codesign first." >&2
  exit 1
fi

rm -rf "$ipa_dir"
mkdir -p "$ipa_dir/Payload"
cp -R "$app_path" "$ipa_dir/Payload/Runner.app"

(
  cd "$ipa_dir"
  zip -qry "$ipa_name" Payload
)

cp "$ipa_dir/$ipa_name" "$ipa_name"
echo "Created $ipa_name"
