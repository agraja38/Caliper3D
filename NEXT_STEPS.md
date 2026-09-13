# Next steps

Use main only; push each tested checkpoint. Preserve any uncommitted physical-device signing configuration. Do not change v1.0.0 or create a release/DMG.

## 1. Continue Session 3 at capture source and staging

The user has passed the real Object Capture gate with a mouse scan, successful Finish, review metadata and relaunch persistence. Checkpoint A now supplies tested version-1 frames, manifests, incremental integrity and receiver ordering. Read docs/TransferProtocol.md before extending it.

Production discovery, TLS coordinator and shared pairing UI are now integrated. Verify signed-app Keychain and Bonjour on hardware; the paired iPhone was disconnected. Coordinator loopback tests pass. Mac Pair iPhone opens a bounded first-pair window; normal listener policy accepts stored pins only. Transfer messages remain rejected pending the engine.

## 2. Stream verified datasets into persistent staging

Extend CaptureRepository with a safe UUID-only ready-dataset source boundary. Incrementally hash/read capture.json, Images and Checkpoints; reject links/special files and detect source mutation. Add receiver staging, free-space checks, incremental writes and durable verified-file journals. ResumeDescriptor currently models identity only; rehash disk files before skipping any candidate.

Extend LocalProjectStore for atomic .caliper3d finalization. Version-1 design uses project UUID = capture UUID, with explicit duplicate/conflict results. Preserve originals, metadata and directory structure. No photogrammetry.

## 3. Integrate and verify real transfer

Add real peer selection/pairing and Send to Mac on iPhone; explicit Receive/Decline, progress and completed-project navigation on Mac. Keep demos injected separately. Handle background interruption without promising long-running background execution.

Physically verify the saved mouse dataset: matching codes and both confirmations → explicit receive → byte/hash verification → project in Library → source retained. Relaunch both apps to verify trust, then interrupt/reconnect and validate file-level resume. No real transfer has been tested yet.

## 4. Later

After Session 3 passes end to end, Session 4 is Mac RealityKit photogrammetry. Capture edge cases (flip, tracking interruption, denial recovery, low storage), accessibility and minimum-OS runtime checks also remain unverified. Keep all real scans and signing assets outside Git.
