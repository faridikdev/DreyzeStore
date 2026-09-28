#!/usr/bin/env bash
set -euo pipefail

if [[ $# -ne 2 ]]; then
  echo "Usage: $0 <built DreyzeStore.app> <output .ipa>" >&2
  exit 2
fi

app_path="$1"
output_path="$2"
if [[ ! -d "$app_path" || "$app_path" != *.app ]]; then
  echo "Expected a built .app bundle." >&2
  exit 2
fi
info_plist="$app_path/Info.plist"
if [[ ! -f "$info_plist" ]]; then
  echo "App bundle has no Info.plist." >&2
  exit 2
fi
bundle_identifier="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' "$info_plist")"
if [[ "$bundle_identifier" != "org.dreyzestore.test.store" ]]; then
  echo "Refusing to package bundle ID '$bundle_identifier'; the device-test artifact must use the project test namespace." >&2
  exit 2
fi

output_dir="$(dirname "$output_path")"
mkdir -p "$output_dir"
stage_dir="$(mktemp -d)"
trap 'rm -rf "$stage_dir"' EXIT
mkdir -p "$stage_dir/Payload"
ditto "$app_path" "$stage_dir/Payload/DreyzeStore.app"
ditto -c -k --sequesterRsrc --keepParent "$stage_dir/Payload" "$stage_dir/package.ipa"
mv -f "$stage_dir/package.ipa" "$output_path"
test -s "$output_path"
shasum -a 256 "$output_path"
