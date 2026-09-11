# iPhone Object Capture

Session 2 implementation on main, 2026-09-11. The public v1.0.0 release/tag and marketing version are unchanged. **No complete physical Object Capture scan has been verified.**

## Ownership and state flow

Production composition injects ObjectCaptureFactory, CameraAuthorization and LocalCaptureRepository into CaptureSessionModel. Core defines a MainActor CaptureSessionDriver lifecycle protocol and hardware-independent snapshots; ObjectCaptureDriver in the iOS app owns the live RealityKit session shown by ObjectCaptureView. The old one-shot CaptureService remains for demo/compatibility only. Production never injects demo services.

New Scan → support check → camera permission → unique storage allocation → create session → initializing → ready → detecting → capturing → finishing → completed → inspect files and atomically save metadata → persistent review.

| Actual Apple state | Available app actions |
| --- | --- |
| initializing | Cancel; wait for readiness |
| ready | Start Detection |
| detecting | Adjust Apple's bounding box, Reset Selection, Start Capturing when tracking is normal |
| capturing | Real shot count and feedback; Finish with at least one shot; optional coverage review |
| capturing + completed scan pass | Finish, another angle, or explicitly pause and flip if Apple permits |
| finishing | Wait; no fabricated success or cancellation during finalization |
| completed | Count generated files, save metadata, then open saved review |
| failed | Show capture or storage error; preserve incomplete files |

Commands are checked against both the observed snapshot and the driver's current Apple state. Completion is guarded against duplicate updates. A metadata save failure offers Retry Saving without recapturing. Cancelling while permission is pending cannot later create a camera session.

## Installed SDK decisions

Verified again in the Xcode 26.6 iOS 26.5 `_RealityKit_SwiftUI.swiftinterface`:

- ObjectCaptureSession, isSupported, Configuration, start(imagesDirectory:configuration:), startDetecting() → Bool, resetDetection() → Bool, startCapturing(), finish(), cancel(), pause(), resume(), beginNewScanPass() and beginNewScanPassAfterFlip() are available at the iOS 17 target.
- Observed streams: stateUpdates, feedbackUpdates, numberOfShotsTakenUpdates, userCompletedScanPassUpdates and isPausedUpdates. Their current properties are read together into a coherent UI snapshot.
- cameraTracking and cameraTrackingUpdates exist, but this SDK's Tracking lacks Sendable conformance while Updates requires it. Accessing that stream causes strict-concurrency diagnostics. The adapter uses Swift Observation on the MainActor cameraTracking property instead; no unchecked conformance, detached task or diagnostic suppression is used.
- ObjectCaptureView(session:) owns the visual capture guidance. ObjectCapturePointCloudView(session:) is optional while the live session is paused. showShotLocations(true) is gated to iOS 18+.
- Feedback mapping covers distance, motion, light, visibility, flipping and over-capture. objectNotDetected is gated to iOS 17.4+. Unknown feedback remains available in Apple's own overlay. Tracking reasons map independently to short guidance; no invented completion percentage.

`configuration.isOverCaptureEnabled = true`: Apple identifies this option as appropriate for captures intended for Mac reconstruction. `configuration.checkpointDirectory` points to a unique empty directory. Checkpoints are retained as optional reconstruction inputs, **not a promise that a saved interrupted capture can resume**. [Over-capture](https://developer.apple.com/documentation/realitykit/objectcapturesession/configuration-swift.struct/isovercaptureenabled), [checkpoints](https://developer.apple.com/documentation/realitykit/objectcapturesession/configuration-swift.struct/checkpointdirectory).

After a completed pass, another angle uses beginNewScanPass(). A flip is optional: pause, physically flip, confirm, then beginNewScanPassAfterFlip() and resume. Apple returns to ready for a new object selection. The action is hidden when objectNotFlippable is reported. [Apple's flip lifecycle](https://developer.apple.com/documentation/realitykit/objectcapturesession/beginnewscanpassafterflip()).

## Support and permission

Simulator builds return unsupported before constructing any real session. Physical devices use ObjectCaptureSession.isSupported, never model-name or LiDAR heuristics. AVFoundation is used only to inspect/request video authorization; no AVCaptureSession is created. The permission request occurs only after New Scan and a successful support check. Denied access links to app Settings; restricted access explains the restriction without repeated requests.

## Persistent storage

App container: `Library/Application Support/Caliper3D/Captures/<UUID>/`

```
capture.json
Images/
Checkpoints/
```

Allocation stages empty directories and metadata, then moves them to a new UUID directory. A 100 MiB startup free-space reserve is a basic preflight, not an estimate of a complete scan's needs. RealityKit remains responsible for capture-time storage limits. Human-readable names are metadata only. Real CaptureRecord stores schema 1, UUID, name, dates, status, actual image count and dataset bytes; no serialized absolute paths. Legacy demo JSON remains decodable through optional new fields.

Only Apple's completed state invokes completion. The repository counts nonempty HEIC/HEIF/JPEG/PNG files directly under Images and sums regular dataset-file sizes recursively, excluding capture.json. Ready-library loading rechecks file statistics and rejects inconsistent or unsafe datasets. Preview generation downsamples at most three candidate photos to a 640-pixel JPEG outside MainActor and never alters originals.

Metadata writes are atomic. Rename never changes the UUID directory. Confirmed deletion accepts only a UUID, verifies matching metadata and checks the owned directory tree before removal. Symlinks in datasets or custom ancestors are rejected, including before creation of a missing leaf. Darwin's exact /var → private/var and /tmp → private/tmp system aliases are allowed; app-controlled symlinks are not. This is an app-private repository, not an importer of hostile concurrently modified filesystem trees.

## Interruptions and incomplete data

Background/inactive live scanning pauses; initialization remembers a pending pause. Returning to foreground requires explicit Resume. The camera permission dialog does not spuriously pause a scan that has not started. Coverage review and the cancellation prompt pause capture. Finishing is allowed to settle before saving; it is not paused by the app.

Cancel/failure preserves Images and Checkpoints and marks metadata interrupted/failed where writable. Saved captures are never deleted by cancellation. At launch, non-ready records appear separately as Incomplete Captures. Corrupt/unknown metadata is counted and preserved without preventing healthy captures from loading. There is no blind stale-data cleanup and no resume-after-relaunch claim. A process kill during finishing/saving may leave an incomplete dataset; recovery validation remains future work.

## Verification and outstanding device run

- Repository and lifecycle tests cover serialization, legacy demo decoding, allocation, completion/file statistics, rename, targeted deletion, symlinks, corrupt/mismatched metadata, low disk, thumbnails, incomplete preservation, permission outcomes, pending-permission cancellation, state/action gating, pass/flip handling, save retry and background pause.
- Mac and iOS Simulator compile checks, plus unsigned iPhoneOS compilation, were run. Strict-concurrency package checks are included in the session evidence.
- Simulator production mode showed the unsupported screen without a permission request. Demo capture → review → simulated transfer completed. A clearly labeled synthetic fixture outside Git exercised production review/preview, rename, relaunch persistence and the delete confirmation; it was not an Object Capture scan.
- A paired iPhone was visible, but no signing team/provisioning configuration is present for this target. No signing assets were created, no physical capture was started, and isSupported was not evaluated on that phone.

Next gate: configure signing locally, run the ordinary Caliper3DCapture scheme on a supported iPhone, verify permission/detection/real image acquisition/shot counts/full pass/finish/completed/persistent files/relaunch, then interruption, flip and storage-pressure behavior. Keep captures outside Git. Do not start networking until that physical capture gate passes.
