# Verified development environment

Inspected 2026-09-10 on an Apple Silicon Mac.

| Tool | Installed |
| --- | --- |
| Xcode | 26.6, build 17F113 |
| Swift | 6.3.3, swiftlang-6.3.3.1.3, clang-2100.1.1.101 |
| macOS SDK | 26.5 |
| iOS / Simulator SDK | 26.5 |
| Simulator runtime | iOS 26.3 |
| Project generator | XcodeGen 2.46.0 |
| Deployment targets | macOS 14.0, iOS 17.0 |

Swift packages use tools version 5.9. App targets use Swift 5 language mode with complete strict concurrency checking. Swift 6 mode migration is a future validation task. No external package dependencies.

## SDK inspection

Verified declarations directly under the installed SDK System/Library/Frameworks:
- `_RealityKit_SwiftUI.framework/Modules/...swiftinterface`: `ObjectCaptureSession` and `ObjectCaptureView(session:)` are iOS 17+. `ObjectCaptureSession` is MainActor isolated and exposes `isSupported`, `state`, `stateUpdates` and `feedbackUpdates`. This Apple-required isolation must be accommodated when implementing the capture adapter.
- `RealityFoundation.framework/Modules/...swiftinterface`: `PhotogrammetrySession` exposes `isSupported`, `process(requests:)`, `outputs` and `cancel()`.
- Mac `_RealityKit_SwiftUI`: `RealityView` requires macOS 15. The app instead uses public `ARView(frame:)` (macOS 10.15+) through NSViewRepresentable, plus ModelEntity, PerspectiveCamera and DirectionalLight.

Inspect these interfaces again before implementing real capture; a successful Simulator build is not evidence of physical Object Capture support. Xcode enumerated a physical iPhone, but this session did not install to it, use its camera, or verify hardware capabilities. No signing team is configured by this project.

## Reproduce

```sh
xcodebuild -version
swift --version
xcodebuild -showsdks
xcrun simctl list devices available
./Scripts/verify.sh
```

The checked-in project/workspace builds without XcodeGen. After editing project.yml, regenerate using `xcodegen generate`. Unsigned compile checks use CODE_SIGNING_ALLOWED=NO; device installation requires selecting a personal team in Xcode.

## Simulator destination issue and workaround

Xcode's scheme-based generic iOS Simulator destination reported “iOS 26.5 is not installed” despite the installed SDK. An attempted official `xcodebuild -downloadPlatform iOS -architectureVariant arm64` failed with an Apple asset-catalog timeout. No SDK files or security settings were modified.

Target-level compilation succeeds using `-target Caliper3DCapture -sdk iphonesimulator` (the verification script uses this). The resulting app was installed and launched using simctl on the already installed iOS 26.3 iPhone 17 Pro Simulator. Onboarding and the complete demo flow were manually verified there. Scheme-based Run may require repairing/downloading the platform in Xcode Settings → Components; this does not block source compilation.

## Session 2 SDK reinspection

Reverified the iOS 26.5 Swift interface and compiled the production driver. All requested ObjectCaptureSession lifecycle APIs and update properties are present at iOS 17; ObjectCapturePointCloudView.showShotLocations requires iOS 18 and feedback.objectNotDetected requires iOS 17.4. Tracking lacks the Sendable conformance required by cameraTrackingUpdates in this SDK; Swift Observation on the MainActor property avoids crossing that boundary. No unsafe conformance or warning suppression was added. See docs/ObjectCapture.md for the complete decision record. The paired physical phone was not used because the iPhone target has no configured signing team.
