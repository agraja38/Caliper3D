#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
for package in Caliper3DCore Caliper3DTransfer Caliper3DInstaller; do
  swift test --package-path "Packages/$package"
done
swift build --package-path Packages/Caliper3DMesh
xcodebuild -project Caliper3D.xcodeproj -scheme Caliper3D -destination 'generic/platform=macOS' -derivedDataPath DerivedData CODE_SIGNING_ALLOWED=NO build
xcodebuild -project Caliper3D.xcodeproj -scheme Caliper3DCapture -destination 'generic/platform=iOS Simulator' -derivedDataPath DerivedData CODE_SIGNING_ALLOWED=NO build
