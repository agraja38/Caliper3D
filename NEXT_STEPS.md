# Next steps

Use main only; commit/push tested checkpoints. Preserve local signing and real datasets. Do not change v1.0.0 or publish a release/DMG.

## 1. Finish Session 3 validation

The protocol/security, production coordinator/UI, source capability, staging/resume and atomic project finalization are implemented. Do not redesign them. Read docs/TransferProtocol.md and run Scripts/verify.sh before changes.

Run both signed apps on the same local network. Mac Devices → Pair iPhone; iPhone Connect to Mac → Pair. Compare codes and confirm on both. Relaunch both and reconnect using the saved pin to verify Keychain persistence. Resolve actual Bonjour/local-network/signing failures without weakening TLS or sandboxing.

Send the user's saved mouse capture. Mac must explicitly accept; verify real byte progress, all hashes, a valid `.caliper3d` in Library, Open Project, and the unchanged source capture on iPhone. No physical transfer is claimed yet. The iPhone was disconnected during inspection.

## 2. Exercise physical interruption and reliability

Cancel or interrupt an in-progress transfer, reconnect, send again and confirm verified files are rehashed/skipped. Also test Mac decline, duplicate capture, changed UUID-conflicting dataset, permission denial, insufficient disk and iPhone background behavior. Loopback tests cover core ordering and file-level resume; hardware remains the gate.

Keep incomplete Incoming data for retries. Consider an explicit safe cleanup UI for abandoned incoming/hidden project staging in a later hardening pass, without deleting recoverable captures automatically.

## 3. After the real transfer gate

Session 4: Mac RealityKit Photogrammetry reconstruction. Do not begin until a real dataset has been securely received, verified, persisted and reopened. Capture edge cases, minimum-OS runtime and accessibility checks also remain pending.
