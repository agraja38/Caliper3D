#!/bin/bash
# Build a universal, ad-hoc-signed Mac distribution. Not Developer ID notarized.
set -euo pipefail
cd "$(dirname "$0")/.."
version=1.0.0
output="$PWD/dist"
staging=$(mktemp -d "${TMPDIR:-/tmp}/caliper3d-release.XXXXXX")
trap 'rm -rf "$staging"' EXIT
mkdir -p "$output"
xcodebuild -project Caliper3D.xcodeproj -scheme Caliper3D -configuration Release \
  -destination 'generic/platform=macOS' -derivedDataPath DerivedData \
  ARCHS='arm64 x86_64' ONLY_ACTIVE_ARCH=NO CODE_SIGNING_ALLOWED=NO build
/usr/bin/ditto DerivedData/Build/Products/Release/Caliper3D.app "$staging/Caliper3D.app"
/usr/bin/codesign --force --sign - --entitlements Apps/Caliper3D/Caliper3D.entitlements "$staging/Caliper3D.app"
/usr/bin/codesign --verify --deep --strict "$staging/Caliper3D.app"
ln -s /Applications "$staging/Applications"
printf '%s\n' 'Caliper3D 1.0.0 — foundation/demo release' \
  'Requires macOS 14 or later. Universal: Apple Silicon and Intel.' \
  'Ad-hoc signed, not Developer ID signed or notarized. macOS may block first launch.' \
  'See the release README for installation details. Live scanning is not implemented yet.' > "$staging/READ ME.txt"
/usr/bin/hdiutil create -volname "Caliper3D $version" -srcfolder "$staging" -ov \
  -format UDZO "$output/Caliper3D-$version.dmg"
/usr/bin/hdiutil verify "$output/Caliper3D-$version.dmg"
cp Scripts/install.sh "$output/install.sh"
(cd "$output" && /usr/bin/shasum -a 256 "Caliper3D-$version.dmg" > "Caliper3D-$version.dmg.sha256")
