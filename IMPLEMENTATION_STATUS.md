# Implementation status

Updated 2026-09-10. Working branch: main (single-branch workflow requested by the owner). Version: **1.0.0** (build 1). This is a native foundation/demo release, not a live 3D scanner.

## Complete for this milestone

- Checked-in Xcode workspace/project and reproducible XcodeGen specification; macOS 14 and iOS 17 targets, normal and Demo schemes, configurable bundle IDs, no developer team.
- Four local Swift packages: Core, Transfer, Mesh, Installer. No third-party runtime dependencies.
- Schema-1 Codable manifest, validation and explicit future-schema rejection; UUID/name/dates/device/capture/reconstruction/unit/dimension/mesh-statistics fields.
- Actor-backed package creation/list/open and non-destructive photo copying; fixed subdirectories, UUID disk names, staged creation, duplicate protection, bounded manifest reads and symlink checks.
- Mac NavigationSplitView, welcome actions, Library, Devices, Processing, native Settings, shortcuts, context menu, optional project inspector and error presentation. Open panel and incoming project URL handling.
- RealityKit demo block, rotation/zoom/reset, reference dimensions with unit conversion, clearly labeled synthetic geometry.
- Injected mock device/capture/transfer/reconstruction services; cancellation, explicit unavailable production capture/transfer, no real sockets or fake success for real data.
- iPhone three-page onboarding, home, temporary recent demo captures, compatibility → capture → review → transfer flow.
- Protocols for discovery, transfer, storage, capture, photogrammetry, mesh processing/analysis/export and companion installation status.
- OSLog categories and privacy/security/contribution/license documentation.

## Verification actually run

- `./Scripts/verify.sh`: passed after final code changes.
- Core: 12 XCTest tests passed; Transfer: 6 passed; Installer: 1 passed. **19 tests, zero failures.** Mesh contract module builds; it has no implementation to test yet.
- macOS app: unsigned xcodebuild build passed for the generic Mac destination.
- iOS Simulator app: unsigned target-level xcodebuild with iphonesimulator SDK passed (arm64/x86_64).
- Runtime smoke checks: Mac welcome → create demo → rendered viewport → simulate reconstruction → completed Processing job; relaunch retained the project in Library; open saved demo and show inspector. Verified accessible rotation/zoom/reset labels after correction.
- iPhone 17 Pro Simulator on iOS 26.3: all onboarding pages → home → New Scan → review → simulated transfer completion. UI screenshots inspected for Mac dark appearance and iPhone light appearance.
- Graphify AST update run successfully. Generated local graph is ignored.
- Build messages include harmless AppIntents metadata extraction skipping; no Swift compiler errors in final checks.

## Partial / limitations

- Project storage supports creation/import/open, not rename/delete, migrations, bookmarks, asset catalogs or processing provenance. One invalid package currently makes library loading report an error. Imported extensions/basic file bounds are checked, but image decoding, aggregate quotas and free-space checks remain to be added before reconstruction.
- Finder URL handling is implemented; end-to-end Finder association behavior with a signed installed build is not yet verified.
- Capture and photogrammetry contracts support demos; real streaming session lifecycle/progress adapters remain to be designed alongside SDK integration.
- Devices and processing are explicit simulations. Demo processing does not create a model file or mark a real reconstruction complete. Jobs are in-memory and reset after relaunch.
- iPhone demo records are metadata only, temporary, and contain no images. The two apps do not exchange demo data.
- No automated UI test suite yet; runtime checks above were manual using UI automation tools.

## Unimplemented

Live ObjectCaptureSession/ObjectCaptureView integration, camera permission flow, physical capability detection, persistent real capture/review, authenticated Bonjour discovery/pairing, Network.framework file transfer, real PhotogrammetrySession reconstruction, real mesh import/rendering, mesh cleanup/smoothing, calibrated measurements, STL export and companion installation/provisioning. Clean/Measure/Export production controls are hidden.

## Environment issue / blocked verification

Xcode's scheme destination resolution requires an iOS 26.5 platform component that it considers missing. The official runtime download timed out. Target-level Simulator compilation and execution on existing iOS 26.3 succeeded, so this is not a compilation blocker. See docs/Environment.md. The v1.0.0 Mac distribution is universal (arm64/x86_64), ad-hoc signed and packaged as a verified DMG. Developer ID signing/notarization remain unavailable; the existing Apple Development identity was not used for distribution.

## Requires real-device verification

Compatible LiDAR/Object Capture support, camera permission denial/recovery, capture feedback, tracking interruption, thermal/storage pressure, real image/depth quality, multi-angle capture, background/resume behavior, real LAN pairing/permissions/transfers and Mac reconstruction fidelity. Xcode listed a physical phone, but no physical-device capture or installation was performed. macOS 14/iOS 17 minimum-runtime behavior, VoiceOver and broad Dynamic Type testing also remain outstanding.

## v1.0.0 distribution

`Scripts/package-release.sh` builds the universal Release app, ad-hoc signs it with sandbox entitlements, verifies its signature, creates/verifies the DMG and generates a SHA-256 checksum. `Scripts/install.sh` downloads the version-pinned asset, verifies integrity/version/signature, and installs to ~/Applications without sudo or replacing existing installations. Release assets belong in GitHub Releases; dist/ is ignored. Both app targets declare marketing version 1.0.0/build 1. The DMG includes only the Mac application.
