#!/usr/bin/env bash
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
output_dir="${1:-${repo_root}/artifacts/device-test}"
derived_data="${2:-${repo_root}/.build/device-test-derived}"
project="${repo_root}/ios/DeviceTestSample/DreyzeDeviceTest.xcodeproj"
app_path="${derived_data}/Build/Products/Release-iphoneos/DreyzeDeviceTest.app"

mkdir -p "$output_dir"
stage_dir="$(mktemp -d)"
trap 'rm -rf "$stage_dir"' EXIT
xcodebuild build \
  -project "$project" \
  -scheme DreyzeDeviceTest \
  -configuration Release \
  -sdk iphoneos \
  -destination 'generic/platform=iOS' \
  -derivedDataPath "$derived_data" \
  CODE_SIGNING_ALLOWED=NO

test -d "$app_path"
mkdir -p "$stage_dir/Payload"
ditto "$app_path" "$stage_dir/Payload/DreyzeDeviceTest.app"
ditto -c -k --sequesterRsrc --keepParent "$stage_dir/Payload" "$stage_dir/DreyzeDeviceTest-sample.ipa"
mv -f "$stage_dir/DreyzeDeviceTest-sample.ipa" "$output_dir/DreyzeDeviceTest-sample.ipa"
test -s "$output_dir/DreyzeDeviceTest-sample.ipa"
shasum -a 256 "$output_dir/DreyzeDeviceTest-sample.ipa"
