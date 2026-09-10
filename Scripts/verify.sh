#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
for package in Caliper3DCore Caliper3DTransfer Caliper3DInstaller; do
  swift test --package-path "Packages/$package"
done
swift build --package-path Packages/Caliper3DMesh
xcodebuild -project Caliper3D.xcodeproj -scheme Caliper3D -destination 'generic/platform=macOS' -derivedDataPath DerivedData CODE_SIGNING_ALLOWED=NO build
# Target-level compile does not require a matching installed Simulator runtime.
xcodebuild -project Caliper3D.xcodeproj -target Caliper3DCapture -sdk iphonesimulator -configuration Debug CODE_SIGNING_ALLOWED=NO ONLY_ACTIVE_ARCH=NO SYMROOT="$PWD/DerivedData/Build/Products" build
