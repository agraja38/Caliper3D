# Next steps

Read PROJECT_SPEC.md and IMPLEMENTATION_STATUS.md first. Use development; do not rewrite history. Run Scripts/verify.sh and keep the handover files current.

## 1. Real iPhone Object Capture — next milestone

- Inspect current installed `_RealityKit_SwiftUI` SDK interfaces before coding. ObjectCaptureSession and ObjectCaptureView are iOS 17+, with MainActor-isolated session APIs.
- Add a production capture adapter and event/state contract for initializing, ready, detecting, capturing, finishing, completed, failed; expose actual progress/feedback and explicit finish/cancel. Keep UI-facing bridging small and account for Apple's required isolation.
- Check actual support and camera permission. Preserve useful unavailable/simulator explanations; retain independently injected demos.
- Create unique capture directories with real image/depth/checkpoint storage, persistent metadata, review and safe deletion. Handle disk pressure, denial, interruptions, app backgrounding and recovery.
- Verify on a compatible physical LiDAR iPhone. Do not infer Object Capture capability solely from a model name or ARKit depth support.

## 2. Secure local discovery and transfer

- Specify the versioned wire protocol and pairing threat model before activating a listener. Use Network.framework + Bonjour, explicit peer approval and authenticated encrypted transport.
- Add staged bounded transfer, integrity validation, file-count/aggregate quotas, full path/symlink defenses, disk checks, cancellation and resumability. SHA-256 alone is not sender authentication.
- Test malformed frames, traversal, failed peers, truncation, mismatch, timeouts and recovery. Never mix demo transport with real captures.

## 3. Real Mac reconstruction

- Add PhotogrammetrySession adapter with support checks, output-event mapping, cancellation, errors and durable job state.
- Validate input image contents and capacity before submitting. Preserve originals; write unique reconstruction outputs and explicit manifest asset/provenance records with a schema migration strategy.
- Load real output geometry into the central RealityKit viewport. Persist only verified successful results.

## 4. Foundation hardening

- Add app state-machine and UI automation tests, VoiceOver/Dynamic Type checks, minimum OS runtime coverage and signed-build document-opening checks.
- Make library enumeration tolerate/report individual corrupt packages; add recent external projects with security-scoped bookmarks, rename/delete, aggregate import limits, free-space checks and robust hostile-package validation before asset loading.
- Consider Swift 6 language mode once all protocol/SDK actor-isolation boundaries are implemented.
- Repair Xcode's iOS 26.5 platform component for scheme-based Simulator Run; current target-level build plus installed iOS 26.3 runtime works. No signing credentials are in the project.

## 5. Mesh tools and companion setup

- Implement non-destructive cleanup/smoothing, mesh statistics, calibrated dimensions/units and validated STL export through the existing contracts.
- Design a safe Xcode/provisioning-based companion setup separately; installation status is currently unknown. Do not add insecure sideloading.
