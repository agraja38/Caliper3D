# Implementation status

Updated 2026-09-11. Main-only workflow. Public app version remains 1.0.0/build 1; no new release, tag change or DMG in Session 2.

## Implemented on main

- Session 1 native Mac and iPhone shells, four shared packages, versioned Mac project storage/import, demo viewport/jobs, Settings and injected demos remain intact.
- Production iPhone RealityKit Object Capture driver and full-screen ObjectCaptureView, using a live MainActor lifecycle boundary rather than the one-shot demo capture method.
- Authoritative support check before session construction; Simulator refuses real capture. Testable camera authorization with denied/restricted handling and Settings action.
- Detection, bounding-box selection/reset, guided capture, actual shot counts, feedback/tracking, completed-pass choices, optional flip and paused point-cloud coverage review.
- Mac-oriented over-capture configuration and a unique empty checkpoint directory; no competing camera pipeline.
- Completion waits for Apple's completed state, then inspects files and saves metadata. Storage failures are separate from camera errors; failed metadata saves can retry.
- Persistent UUID capture repository, actual file counts/size, atomic metadata, safe rename, confirmed targeted deletion, bounded thumbnails and legacy demo decoding.
- Persistent ready/incomplete libraries; corrupt packages are reported without hiding healthy ones. Cancel/failure preserves incomplete data. Background pause and explicit resume within the same live session.
- Production review with preview, name/date/count/size, Ready to send and Save for Later. Real transfer is not offered; demo transfer remains separate.

## Verification

Baseline Scripts/verify.sh passed before major changes (19 tests and both apps).

Final ./Scripts/verify.sh passed: 43 Core tests, 6 Transfer tests and 1 Installer test (50 total, zero failures), Mesh package build, macOS app build and iOS Simulator app compilation. Core also passed all 43 tests with -strict-concurrency=complete. Unsigned iPhoneOS compilation passed. These compile checks do not verify camera hardware. Final verification reported no Swift compiler warnings; the device build may emit the standard unused AppIntents metadata notice.

Simulator runtime checks performed:
- Ordinary app → New Scan → unsupported screen, without creating an ObjectCaptureSession or requesting camera access.
- Demo app → New Scan → simulated capture → review → simulated transfer complete.
- A labeled synthetic storage fixture → persistent review/preview/count/size → rename → Simulator restart/relaunch → renamed capture retained → delete confirmation shown and dismissed. This is storage/UI verification, not a real scan.

## Physical capture verification: PASSED (user-reported at Session 3 start)

The user installed and launched Caliper3D Capture on a supported physical iPhone, scanned a computer mouse with real Object Capture, completed Finish, and saw Capture Review with the real capture, photo count, storage size and Ready to send. After terminating and reopening the app, the mouse capture remained in Recent Captures. This confirms the basic capture-to-persistent-review hardware gate.

No additional physical tests are claimed: permission denial/recovery, full-pass detection, additional passes, flip, interruption recovery, low storage, depth quality and network transfer remain unverified. Session 3 began with a clean checkout and no local signing diff; personal signing settings and scan data are not committed.

## Partial / limitations

- Captured production data is ready for future UUID-based transfer integration; no network implementation was added.
- Same-session pause/resume is implemented; resume of a saved incomplete session is not supported. Checkpoints do not imply capture-session restoration.
- A process kill during finishing/metadata commit can leave an incomplete dataset. Files are preserved; automatic recovery/cleanup is deliberately absent.
- Apple cameraTrackingUpdates triggers a missing-Sendable SDK warning; tracking is safely observed through its MainActor observable property instead. See docs/ObjectCapture.md.
- File counting trusts recognized nonempty files produced by Object Capture; this is not a general hostile-image import pipeline. Owned-path/symlink checks are not a guarantee against a malicious concurrent filesystem writer outside the app-private model.
- Minimum OS runtime, VoiceOver, large Dynamic Type and real thermal/storage-pressure tests remain pending. Simulator preview/rename checks used synthetic data only.
- Existing Mac library limitations remain: no general project rename/delete/bookmarks or migrations, and corrupt Mac packages can prevent library loading. Mac code was not redesigned.

## Unimplemented / outside Session 2

Authenticated pairing, Bonjour/Network.framework transfer, real Mac photogrammetry, mesh cleanup/smoothing, calibrated measurement, STL export, companion provisioning/installation and signed/notarized distribution. Existing v1.0.0 release assets are unchanged.

See docs/ObjectCapture.md for API decisions, storage layout, lifecycle and the exact physical-device checklist.
