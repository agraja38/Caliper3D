# Next steps

Use main only. Read PROJECT_SPEC.md, IMPLEMENTATION_STATUS.md and docs/ObjectCapture.md. Do not rewrite history or alter v1.0.0 release/tag.

## 1. Session 3: secure local transfer

The user has verified a real mouse scan, successful Finish, review metadata and persistence after relaunch. Implement the versioned, bounded transfer protocol, TLS pairing and pinned trust, streamed integrity-checked staging/resume, and explicit receive/send UI. Transfer must finish as a valid .caliper3d project before any reconstruction work.

Then verify permission denial/recovery, multiple passes, optional flip, point-cloud review, background/pause/resume, tracking failure, cancel, low storage and metadata write failure. Confirm that the driver releases the camera promptly and that incomplete datasets remain distinct from ready captures. Keep real images outside Git.

## 2. Capture reliability after device evidence

- Fix any hardware lifecycle issues before widening scope.
- Add automated iOS UI tests and exercise VoiceOver, larger Dynamic Type and iOS 17/17.4/18 availability paths.
- Decide how to recover a dataset interrupted during finishing/metadata save. Never mark it ready solely because photos exist, or assume checkpoint files restore the capture session.
- Consider diagnostics for unreadable captures and explicit export/recovery of incomplete data; retain safe UUID ownership checks and no blind cleanup.

## 3. Session 3, only after capture is reliable

Design authenticated local Network.framework transfer with explicit pairing, encryption, bounded messages/files, safe paths, staged completion, integrity validation and recovery. Real captures are stored by UUID under app-owned Captures/<UUID>; resolve through a validated repository boundary. Do not use Multipeer Connectivity or mix demo transport with real datasets.

Mac reconstruction and mesh/STL work follow reliable capture and transfer. No release/version bump is required merely for this development milestone.
