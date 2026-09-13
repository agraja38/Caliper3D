# Local capture transfer protocol — version 1

Session 3 integrates the version-1 protocol, TLS/pairing, production Bonjour/UI, source streaming, durable staging/resume and atomic project finalization. Synthetic TLS loopback transfers pass; physical iPhone-to-Mac transfer and signed-app Keychain persistence remain unverified.

## Transport and security boundary

LocalTLSParameters builds Network.framework TLS 1.3 with mutual certificate proof. IdentityCertificate serializes a fixed X.509 P-256 self-issued certificate and uses Security for random keys and ECDSA SHA-256 signing; no cipher/key-exchange implementation is added. Certificates carry digitalSignature and client/server EKU, non-CA constraints and ten-year validity. SecIdentityCreate verifies the key/certificate association. Certificate serialization follows [RFC 5280](https://www.rfc-editor.org/rfc/rfc5280). These identities are for app-local pinning, not public Web PKI or Apple code signing.

KeychainIdentityRepository persists the certificate/private material as a protected app-scoped Keychain item, WhenUnlockedThisDeviceOnly, non-synchronizing and using the data-protection Keychain. Corrupt or inaccessible identity material fails without silently rotating identity. KeychainTrustRepository stores at most 100 approved peers in the same protected storage. Forget removes the pin. Keychain persistence is implemented but still needs signed-app/relaunch verification; unit tests serialize trust and identity material in memory only.

TLS verification requires one presented certificate, validates it using Security BasicX509 with that exact local anchor and disables network certificate fetching. Pinned mode rejects a fingerprint mismatch during the handshake. First-pair mode accepts a valid self-issued TLS identity **only for an explicit pairing attempt**, with no transfer authorization. Peer fingerprints are SHA-256 over actual leaf certificate DER, never Bonjour names or self-reported hello values.

TLSChannel reads actual peer certificate metadata and exports 32 bytes through Apple's sec_protocol_metadata_create_secret, using label `EXPORTER-Caliper3D-pairing-v1`. This is the TLS exporter defined by [RFC 8446 section 7.5](https://www.rfc-editor.org/rfc/rfc8446#section-7.5). The secret remains in memory and must never be logged/serialized. Channel startup has a 15-second timeout; outstanding read/write operations have a 180-second deadline. One reader/writer and bounded receives provide backpressure. Cancel closes the connection. Static OSLog messages omit identities, codes and key material.

### First-pair protocol component

PairingSession binds both certificate fingerprints, fixed phone/Mac roles, the actual TLS exporter and independently random 32-byte pairing nonces. Both sides must send their commitment before receiving a reveal:

1. Context is UTF-8 `Caliper3D pairing v1\n<phone fingerprint>\n<Mac fingerprint>\n`.
2. Commitment is SHA-256(context + role + newline + local nonce), sent as lowercase hex.
3. After receiving the peer commitment, reveal the nonce. Reject a reveal that does not match the commitment or arrives out of order.
4. Transcript is context + phone nonce + Mac nonce. HMAC-SHA256 keyed by the TLS exporter over `code\n` + transcript produces the code: first four bytes as big-endian UInt32 modulo 1,000,000, formatted `123 456`.
5. Each side's explicit user confirmation sends HMAC-SHA256(exporter, `confirmation\n` + transcript). Only after local and peer confirmation does the session become approved. Pairing expires after 120 seconds and rejection clears the displayed code.

This uses standard hashes/MACs and TLS channel binding, not custom encryption. Commit/reveal prevents adaptive nonce selection after seeing the peer's nonce. The short code provides approximately 20 bits of human verification, not unlimited-attempt authentication. The coordinator enforces connection/attempt rate limits and one active pairing UI. Users must compare the code on their own two devices. No approval or automatic trust may come from a Bonjour advertisement.

ReceiveProtocol.authorizePeer remains a local integration hook. The coordinator first completes PairingSession approval (or match a stored pin on reconnect), ensure its hello fingerprint matches TLSBinding, and awaits Keychain persistence before granting transfer authorization. Pairing messages do not directly authorize ReceiveProtocol. The production coordinator owns this boundary.

## Framing

Every frame is `kind: UInt8 | payloadLength: UInt32 big-endian | payload bytes`.

| Kind | Payload | Maximum |
| --- | --- | --- |
| 1 | UTF-8 JSON control envelope | 4 MiB |
| 2 | Raw file bytes, never Base64 | 256 KiB |

Zero-length frames and unknown kinds are rejected. Reject a length above its kind's limit immediately after the five-byte header, before buffering its payload. Each transport receive feeds at most 256 KiB to FrameDecoder. It buffers at most one incomplete bounded frame plus one receive, handles arbitrary fragmentation/coalescing, and rejects truncated EOF. Decode failure poisons the decoder; close the connection instead of attempting resynchronization.

Control envelope example: `{"type":"ping","version":1}`. Payload-bearing messages also contain `payload`. Version is checked before decoding payload. Unknown versions/types, wrong payload schema and malformed JSON are rejected. Unknown extra object keys are ignored within version 1; required fields are always validated. This is not a serialization of Swift enum internals.

| Type | Payload schema | Direction / meaning |
| --- | --- | --- |
| hello / helloResponse | name, operatingSystem, optional objectCaptureSupported, identityFingerprint, nonce | Sender / receiver greeting; fingerprint and nonce are 64 lowercase hex digits |
| pairingCommitment | sha256 | Both sides, before either nonce is revealed |
| pairingReveal | nonce | Both sides, after receiving the peer commitment |
| pairingConfirmation | transcriptDigest | Both explicit confirmations; field contains the exporter-bound confirmation MAC |
| pairingRejected | optional transferID, code | Pairing refused |
| transferOffer | TransferManifest | iPhone → Mac; full bounded manifest before any file data |
| transferAccepted | transferID, manifestDigest, verifiedFileIndices | Mac → iPhone, only after user acceptance and disk revalidation |
| transferRejected | optional transferID, code | Mac declines |
| fileBegin / fileComplete | transferID, index | iPhone → Mac; identifies one manifest file |
| transferComplete | transferID, projectID, manifestDigest | Mac → iPhone, only after atomic project finalization |
| cancel / error | optional transferID, code | Either side; bounded machine code, locally mapped user text |
| ping / pong | absent | Liveness; future transport must bound rate and timeout |

No separate progress messages are needed: sender/receiver count actual binary bytes. One file is active at a time. Raw binary belongs to the preceding fileBegin. Exactly the declared number of bytes must arrive before fileComplete. Empty files use fileBegin then fileComplete with no binary frame. The receiver does not accept a sender-generated transferComplete.

## Manifest and limits

TransferManifest fields: version, transferID, captureID, name, createdAt (ISO-8601 UTC ending Z), source (name, operatingSystem, actual objectCaptureSupported), imageCount, totalBytes and ordered files. Each file contains path, bytes (signed 64-bit integer validated nonnegative) and lowercase SHA-256. File count is the files array length. Metadata-only offers are invalid.

Central TransferPolicy bounds: 10,000 files, 16 GiB per file, 128 GiB per dataset, 1,024 UTF-8 bytes per relative path and 255 per component. The complete manifest must also fit the 4 MiB control limit, with envelope headroom. These are upper bounds, not preallocated buffers. Validate aggregate size with checked arithmetic before accepting a transfer.

Only `capture.json`, `Images/**` and `Checkpoints/**` are allowed. capture.json must be nonempty and at most 128 KiB. imageCount must agree with nonempty recognized image files directly under Images, matching current CaptureRepository semantics. Preserve filenames and subdirectories.

Paths reject absolute/traversal/dot/empty components, backslashes, colons, percent escapes, control characters, trailing dots/spaces and non-NFC byte representations. Duplicate case/diacritic-folded paths and file/directory collisions are rejected conservatively for Apple filesystems. No URL decoding is performed. Disk services must additionally reject symlinks and special files; string validation alone is insufficient.

Manifest identity is SHA-256 of JSON encoded with sorted keys, unescaped slashes and the existing ordered files array (UUID strings and UTC date strings). Use `canonicalData()` on both ends rather than hashing arbitrary received JSON formatting. Changing any field, file order, size or digest invalidates the identity.

## Receiver state and integrity

`awaitingHello → awaitingTrust → idle → offered → receiving → finalizing → completed`.

Local user decline returns offered to idle. Only the secure transport may authorize the peer; only the local receive decision accepts an offer; only the store may report finalized. Binary data before acceptance, concurrent files, duplicate verified indices, mismatched transfer IDs, bad file indices and unexpected control messages fail the session.

FileIntegrityVerifier incrementally updates CryptoKit SHA-256 and actual length in bounded chunks. Truncation, corruption and extra bytes fail; completion can be consumed only once. This primitive does not write files. IncomingCaptureStore writes and verifies successfully before journaling a fileComplete as durable.

Cancel and timeout/disconnect stop the current stream and preserve the set of fully verified file indices. A reconnect starts a new receiver protocol instance, repeats authentication, reoffers the exact manifest and asks for explicit acceptance. ResumeDescriptor binds candidate indices to transfer UUID, capture UUID and manifest digest. IncomingCaptureStore persists this journal identity and rehashes all candidates before acceptance. Disk existence or a journal entry alone must never cause a file to be skipped.

## Disk integration

Resolve the ready source dataset by capture UUID through CaptureRepository. Validate ownership and files, incrementally hash/read them, and prevent or detect mutations while sending. Never use a network-provided source path. Keep the original iPhone capture intact.

Receiver staging uses app-owned `Incoming/<transferUUID>.partial`. Validate the entire manifest and free space before creating files. Persist only verified completion state; rehash candidate completed files after restart. On changed manifests, safely restart incompatible staging. Partial files restart from byte zero in version 1.

After every file verifies, LocalProjectStore atomically creates:

```
<captureUUID>.caliper3d/
  manifest.json
  capture/capture.json
  capture/Images/...
  capture/Checkpoints/...
  reconstruction/
  processed/
  thumbnails/
  logs/
```

Decision: the Mac project UUID equals the capture UUID for version 1, making duplicate imports explicit. Transfer UUID also equals capture UUID, providing a stable retry key; the digest identifies exact manifest contents. Never overwrite an existing project: an identical already-imported capture should return an explicit duplicate result; a changed dataset with that UUID requires a user-visible conflict. This finalization/duplicate behavior is implemented and tested. Set captureMethod objectCapture, real source/count/date and reconstructionState notStarted. Never start photogrammetry in this milestone.

## SDK and privacy notes

Inspected Xcode 26.6 iOS 26.5 Network.swiftinterface: NWBrowser Bonjour descriptors and result/state callbacks, NWListener service/newConnectionHandler, NWConnection receive(minimumIncompleteLength:maximumLength:completion:) and send(content:contentContext:isComplete:completion:), NWParameters(tls:tcp:). Security headers expose local identity, required peer authentication, minimum TLS version, verify blocks and peer-public-key metadata. SecIdentityCreate and TLS exporter signatures were also checked in Security headers. The implemented channel compiles against the installed SDK and has loopback socket tests.

Before enabling networking, retain Mac App Sandbox and add only the client/server network capabilities needed by the implemented connection roles. Both apps must declare `_caliper3d._tcp` and a local-network usage explanation. Both apps have these declarations; Mac has the network server entitlement for accepted TCP connections. Handle denied privacy access without retry loops. Apple documents Bonjour declarations and local-network privacy, including macOS, in [TN3179](https://developer.apple.com/documentation/technotes/tn3179-understanding-local-network-privacy). No background modes or multicast entitlement were added in this checkpoint.

## Verification boundary

Most tests use in-memory frames and synthetic bytes. Two additional tests use real Network.framework TLS loopback connections without Bonjour advertisements. They cover fragmentation/coalescing, bounds, malformed/version errors, safe paths/collisions, manifest totals, incremental corruption/truncation, local authorization gating, ordering, cancel/interruption and resume identity. Loopback tests verify matching live TLS exporters/codes, a bounded binary payload and pinned mismatch rejection. Security identity tests verify certificate parsing/trust and private-key proof. Additional store and coordinator tests now verify actual synthetic disk staging/resume and complete loopback transfer/finalization. Tests do not prove signed-app Keychain persistence, Bonjour or physical transfer. The user-verified mouse scan remains outside Git and has not been sent to Mac by this implementation.

## Production coordinator checkpoint (2026-09-13)

ConnectionCoordinator now integrates discovery and pairing in both apps. Mac advertises the TLS listener; its normal policy accepts the Keychain fingerprint set. Pair iPhone explicitly opens a two-minute first-pair window. iPhone Pair explicitly requests first-pair TLS; Connect to a paired device supplies the selected stored pin. Hello adds optional requiresPairing (absent means false) so reconnect cannot silently downgrade to a fresh pairing. The actual TLS fingerprint must match hello before any pairing message. Trust is saved only after both confirmations, then UI becomes connected. Transfer frames route to the engine only after authenticated trust.

NWBrowser replaces each discovery snapshot, deduplicating service name/type/domain and updating endpoints; these identifiers remain untrusted display/routing data. Connection generation checks prevent cancelled work from restoring a session. Browser failure/waiting stops discovery with Settings guidance rather than retrying indefinitely. iPhone background stops networking; explicit reopening/retry is required. Only one connection/pairing UI is active, with three new attempts per minute and a three-second cooldown.

Mac uses com.apple.security.network.server and retains App Sandbox. It currently initiates no outgoing TCP connections, so client entitlement is not added. Apple's [network server entitlement reference](https://developer.apple.com/documentation/bundleresources/entitlements/com.apple.security.network.server) confirms bidirectional data on accepted TCP connections does not require the client entitlement. Both apps declare the Bonjour type and usage explanation.

Coordinator tests use actual loopback TLS and in-memory injected trust, not Bonjour or personal Keychain data. They verify same code, no trust after one confirmation, paired reconnect, forget revocation and forged hello rejection. Physical pairing and signed-app trust persistence are pending.

## Capture source checkpoint

CaptureRepository.prepareSource(UUID) now issues a read-only CaptureDataSource capability: describe and bounded read(fileIndex, offset, count). Network code receives no source URLs. The repository requires ready metadata, matching UUID/count/bytes and safe owned paths. The reader allows only capture.json, Images and Checkpoints, rejects symlinks/special files, hashes incrementally, bounds file counts/sizes/reads, and checks inode/size/modification date around reads. Metadata changes during preparation invalidate the snapshot. This is an app-private storage boundary; a malicious concurrent filesystem writer is outside the app sandbox threat model.

New CaptureRecord JSON has optional sourceDevice recorded at capture allocation from the actual device and Object Capture support API. Older records remain readable and transferable; missing device/OS are labeled not recorded, and TransferSource.objectCaptureSupported is optional/unknown rather than fabricated. Explicit false is rejected. No legacy scan is modified merely to prepare it.

PreparedCaptureTransfer constructs the existing manifest from that capability. Version 1 uses capture UUID for transfer UUID as well, giving retries/relaunches a stable staging key without writing transport metadata into the source. Any manifest change invalidates the matching journal and triggers safe staging restart; the manifest digest still identifies the exact attempt contents. Total transfer bytes include capture.json, while capture metadata's dataset size excludes it.

## Implemented durable receiver storage

IncomingCaptureStore owns Incoming/<transfer UUID>.partial, with transfer-manifest.json, journal.json, a dataset directory and a single receiving.tmp file. Journals bind the canonical manifest digest and verified indices. Every resume candidate is rehashed from disk; unfinished files restart at byte zero. A changed manifest invalidates the owned staging directory. Symlinks and special files block traversal/deletion. Free-space acceptance reserves remaining bytes plus one finalization copy and 100 MiB of metadata headroom.

LocalProjectStore finalization preserves the dataset under capture/, writes sourceCaptureDigest into manifest.json, and atomically moves a hidden project staging directory into <capture UUID>.caliper3d. Existing UUIDs return duplicate only when the digest and rehashed stored files match; otherwise they conflict. The source iPhone dataset remains untouched. Path depth is limited to 64 components; capture.json is capped at 128 KiB. Production streaming orchestration uses these stores through the authenticated coordinator.

## Live transfer integration (2026-09-14)

A connected iPhone prepares a UUID-issued source, offers its manifest and waits for explicit Mac acceptance. The Mac rehashes journal candidates/checks space, sends their indices, then receives one bounded binary stream per file. The sender skips only accepted indices and counts actual sent bytes; the Mac independently verifies lengths/hashes and journals durable files. No network input selects a source URL or a destination outside the configured Incoming root.

After the final file, the Mac revalidates metadata/files, atomically finalizes the project, removes corresponding staging and sends transferComplete with project ID and manifest digest. Only that acknowledgement shows iPhone success. A lost acknowledgement can be retried; exact duplicates are safe. The Mac Library refreshes, and Devices provides Open Project. Reconstruction is not started.

UI cancellation closes TLS instead of interleaving a cancel control with an in-flight binary write. Verified journal state remains; an unfinished file restarts at zero. iPhone backgrounding follows the same interruption policy. One active connection/transfer is supported; changing destination is explicit. Outstanding network operations time out after 180 seconds, so very slow preparation/finalization may require retry. No automatic background continuation or acceptance is promised.

Coordinator loopback tests cover explicit acceptance/decline, a committed and reopened project, duplicate import, fully verified resume without file frames, and cancellation mid-file in a 64 MiB synthetic transfer followed by pinned reconnect and verified-file resume. Physical mouse transfer remains pending.

## Runtime signing gate and integration review

An isolated ad-hoc Mac runtime failed data-protection Keychain access with errSecMissingEntitlement (-34018); no listener started. The unsigned Simulator production connection flow also stopped at identity access. Both ordinary app targets need properly development-signed builds for physical validation. Select your own team locally in Xcode; do not commit it or switch to unprotected identity storage. The signing-specific error is mapped to actionable UI, and logs contain only the numeric OSStatus. Signed-app Keychain relaunch persistence remains pending.

Review of the live composition: first-pair TLS is exposed only inside the explicit Mac pairing window and an explicit iPhone Pair action; hello fingerprints must match TLS metadata; exporter-bound commitment/reveal precedes code display; trust writes follow both approvals. Transfer routing requires connected/authenticated state, then the receiver additionally requires a user acceptance event before bytes. Pinned mismatch never falls back to pairing. Indexed source capabilities and UUID-configured Incoming/project roots isolate network messages from arbitrary filesystem paths. Limits, hashes and metadata are validated before finalization. Cancellation stops tracked preparation/streaming tasks and closes TLS. Unit and live TLS tests cover trust gating, forged hello, unsolicited binary, ordering, corruption, hostile paths and resume. Physical testing and independent security review remain useful before distribution.
