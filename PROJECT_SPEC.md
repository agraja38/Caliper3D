# Caliper3D project specification

Caliper3D turns a LiDAR-equipped iPhone and a Mac into an open-source, local-first 3D scanning workflow for clean, printable STL models. Caliper3D is the macOS application; Caliper3D Capture is the iPhone companion.

## Platforms and architecture
- Native Swift, SwiftUI, Swift Concurrency. macOS 14+, iOS 17+. No developer team hardcoded.
- iPhone captures camera/LiDAR/Object Capture data; Mac receives captures and performs RealityKit photogrammetry and later mesh cleanup, measurement, calibration and STL export.
- Network.framework + Bonjour for future local discovery/transfer; never Multipeer Connectivity. CryptoKit for integrity/authentication. Model I/O for future mesh import/export. OSLog with private metadata.
- Apps contain UI and injected UI-facing state. Shared packages: Core (models, storage, capture/reconstruction contracts), Transfer (discovery/transfer), Mesh (processing/analysis/export contracts), Installer (installation contracts only).
- Services use protocols and actors for mutable asynchronous data. No global monolithic AppState. MainActor is used for UI-facing state and Apple-mandated live Object Capture session APIs.
- Explicit --demo-mode injects mocks. Demo geometry and capture metadata are synthetic; production never pretends hardware or network operations succeeded.

## UX
Native NavigationSplitView on Mac: Library, New Scan, Devices, Processing; standard Settings. Editor centers the 3D viewport with an optional inspector. Clean/Measure/Export appear only when implemented. Native fonts, symbols, colors, dark mode, shortcuts and restrained chrome. iPhone: onboarding → home → compatibility → capture → review → transfer.

## Project format
A versioned .caliper3d directory package contains manifest.json, capture/, reconstruction/, processed/, thumbnails/, logs/. Manifest tracks schema, UUID, name, dates, source device, capture method, image count, reconstruction state, units, dimensions and mesh statistics. Original capture and reconstruction are immutable inputs to future derived processing. Unknown schema versions fail explicitly; never silently downgrade. Paths must be validated before reading untrusted packages. Generated filenames must not use user-supplied paths.

## Security and privacy
No accounts, cloud backend, analytics, telemetry, subscriptions or web wrappers. No automatic execution of imported content. Future transfer requires explicit peer approval, authenticated encrypted transport, bounded frames/files, safe relative paths, integrity checks, staging and atomic completion, cancellation and disk-space handling. Bonjour discovery alone is not authentication. Never store credentials, signing assets or personal scans in Git. Installer remains an abstraction until safe Xcode/provisioning design is implemented; no insecure sideloading.

## Workflow
Keep all work on main as the single repository branch, per the owner’s updated instruction. Do not create additional branches unless requested. Use logical commits, no force pushes/history rewriting. Keep IMPLEMENTATION_STATUS.md and NEXT_STEPS.md honest and current. Build both targets and test shared packages. Real capture is the next milestone, not a claim of this foundation.

## Foundation implementation decisions
The checked-in Xcode project/workspace is generated from project.yml using XcodeGen; building does not require the generator. Demo schemes pass --demo-mode. App package dependencies are local SwiftPM packages. RealityKit ARView is wrapped for macOS 14 compatibility because RealityView starts at macOS 15. Mac packages use UUID filenames under Application Support with separate demo storage. MIT license. See docs/Architecture.md for storage and concurrency constraints; see docs/Environment.md for the verified SDK and Simulator workaround.

## Distribution
Version 1.0.0 is the foundation/demo milestone, not a complete scanning product. Both targets use MARKETING_VERSION and CURRENT_PROJECT_VERSION in project.yml. Distribute universal Mac DMGs through version-tagged GitHub Releases with SHA-256 checksums and a version-pinned user-local installer. Release binaries are ignored in Git. Until Developer ID signing and notarization are configured, explicitly label downloads as ad-hoc signed/unnotarized and never remove quarantine or disable Gatekeeper in installation scripts. Keep installer and packaging version values aligned for each release.

## Live iPhone capture architecture (Session 2)
Production uses CaptureSessionModel + CaptureSessionDriver/Factory, with a RealityKit ObjectCaptureDriver in the iPhone app. The live session stays MainActor-isolated and is presented by ObjectCaptureView. Core contains Sendable snapshots, permission/repository contracts and the testable lifecycle model; one-shot CaptureService is retained for demos/compatibility only. Never construct a real session without ObjectCaptureSession.isSupported and camera permission. Simulator never creates one.

Capture datasets use a separate schema-1 capture.json under app-private Application Support/Caliper3D/Captures/<UUID>, with Images and Checkpoints directories. Only actual completed sessions with inspected nonempty image files become ready. Human names do not form paths. Cancel/failure preserves incomplete datasets; deletion is explicit and UUID-scoped. Over-capture is enabled for later Mac reconstruction. Checkpoints do not promise saved-session resume. See docs/ObjectCapture.md; a physical end-to-end scan remains unverified.
