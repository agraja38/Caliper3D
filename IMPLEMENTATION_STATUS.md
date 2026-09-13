# Implementation status

Updated 2026-09-14. Main-only workflow. Public version remains 1.0.0/build 1; existing release/tag/DMG unchanged. No personal signing configuration or real scan data was added.

## Implemented

- Native Mac Library/New Scan/Devices/Processing, project storage/photo import, Settings and injected demo viewport/jobs. Native iPhone onboarding and isolated simulator/demo capture/review/transfer remain available.
- Production iPhone Object Capture: authoritative support check, camera permission, live MainActor session, detection/selection, guided capture, actual shots/feedback, additional passes, optional flip/point-cloud review, finish-to-persistent-review, safe UUID storage, rename and confirmed deletion. Incomplete data is preserved.
- Version-1 bounded JSON/binary framing, safe paths and collision checks, practical dataset limits, incremental SHA-256, explicit receiver ordering.
- P-256/X.509 installation identities, protected Keychain identity/trust, TLS 1.3 mutual authentication, certificate pinning, TLS exporter-bound commitment/reveal pairing, both-side confirmation and Forget Device.
- Production NWListener/Bonjour on Mac and NWBrowser on iPhone. First pairing requires explicit Pair iPhone window on Mac and Pair on iPhone; normal reconnect requires stored pins. One active connection/UI, bounded attempts/cooldown and timeouts. Mac sandbox and local-network privacy declarations retained.
- READY capture source capability resolved only by UUID, expected-root/symlink checks, bounded indexed reads, incremental hashes and mutation detection. New captures record actual source-device metadata; older captures retain explicitly unknown historical details.
- Incoming staging, free-space checks, incremental verified writes, durable manifest-bound journal, rehash-before-resume, restart unfinished files from zero, safe changed-manifest invalidation.
- Live authenticated transfer offers and explicit Mac Receive/Decline, binary streaming, byte progress, cancellation, final verification and completion acknowledgement. Source scans remain on iPhone.
- Atomic LocalProjectStore finalization into `<capture UUID>.caliper3d`, preserving capture files and `.notStarted` reconstruction. Exact duplicates reuse the existing project; changed datasets conflict without overwrite.
- Production saved-review Send to Mac, destination connection UI, Mac receiving status and Open Project/Library integration.

## Verification

Final streaming checkpoint: `./Scripts/verify.sh` passed with 112 tests (47 Core, 64 Transfer, 1 Installer), Mesh build, macOS app build and iOS Simulator compilation. Unsigned iPhoneOS compilation also passed. Complete strict-concurrency settings remain enabled; no Swift compiler warnings were introduced (only Xcode's standard unused AppIntents metadata notice).

All six coordinator integration tests passed, including real TLS loopback transfers with synthetic datasets, explicit decline/acceptance, project reopening, duplicate import, fully verified resume, and cancellation during a 64 MiB transfer followed by pinned reconnect and file-level resume.

Tests use generated identities and in-memory trust; they do not prove signed-app Keychain persistence or Bonjour between physical devices. No real capture was read by automated tests.

Earlier Session 2 Simulator checks passed: unsupported production New Scan, full demo capture/review/simulated transfer, synthetic persistent review/rename/relaunch and deletion confirmation. These are not physical network tests.

## Physical capture gate: PASSED (user-reported)

The user installed Caliper3D Capture on a supported iPhone, scanned a physical computer mouse using Object Capture, completed Finish, and saw the real capture with photo count, storage size and Ready to send. After terminating/reopening the app, the saved mouse remained in Recent Captures.

No additional hardware tests are claimed. Physical pairing, matching-code confirmation, signed-app Keychain persistence after relaunch, real mouse transfer, project reopening and interrupted-transfer resume remain pending. The paired iPhone was disconnected when inspected during this continuation.

## Limitations / remaining verification

- Network and storage integration passes synthetic loopback tests; real same-network Bonjour/privacy/signing/Keychain behavior still needs validation on both devices.
- Transfers require foreground iPhone use. Backgrounding closes networking and preserves verified Mac staging; reopen/reconnect and send again. No background-transfer promise.
- One active peer/transfer at a time. Source selection uses the connected paired Mac; disconnect to choose another. No automatic acceptance or deletion.
- Finalization copies the dataset and reserves disk for that copy. Incomplete staging is retained for retry; no automatic expiry. Process death can leave a hidden project staging folder; automatic orphan cleanup is not implemented.
- Saved incomplete Object Capture sessions cannot resume after relaunch. Camera permission recovery, flip/additional passes, thermal/low-storage and minimum-OS/accessibility hardware checks remain pending.
- Owned filesystem checks defend the app-private storage boundary; they are not a guarantee against a malicious concurrent writer with equivalent filesystem access.
- Existing Mac library limitations remain: no general project rename/delete/bookmarks/migration; corrupt packages can prevent library loading.

## Unimplemented / out of scope

Mac photogrammetry, mesh cleanup, calibrated measurement, STL export, companion provisioning/installation and signed/notarized releases. Session 4 must wait for a real verified iPhone-to-Mac capture transfer.
