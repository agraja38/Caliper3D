# Local capture transfer protocol — version 1

Session 3 checkpoint A implements transport-independent framing, control models, manifest validation, incremental integrity verification and receiver sequencing. **There is no production listener, pairing implementation, sender, staging service or transfer UI yet.** The security handshake below remains an integration requirement, not a claim that these models authenticate peers. No real Mac–iPhone transfer has been tested.

## Transport and security boundary

Use Network.framework TLS over TCP on the same local network. Mac advertises `_caliper3d._tcp`; iPhone selects a discovered Mac. Bonjour names and all hello metadata are untrusted until authenticated. Do not enable a plaintext fallback.

Required before opening a production listener:

- Persistent per-installation identity, private keys protected by Keychain/Security. Define and test native identity/certificate creation for both platforms; this checkpoint does not generate certificates or keys.
- Mutual TLS peer proof, TLS 1.3 minimum, and a first-pair verification code bound to both presented identities and the live cryptographic session/transcript. The exact exporter/commitment construction still needs security review and implementation; a random transmitted number or hashing self-reported hello fingerprints alone is insufficient.
- Both devices explicitly approve the same code before trust is persisted. Pin verified identities in Keychain, reject mismatches on reconnect, and implement Forget Device on both platforms. Do not persist trust merely when TLS completes.
- Bounded handshake timeouts, pairing attempt limits and rejection handling. Network callbacks must never call `authorizePeer` just because a `pairingConfirmation` message arrived.

`ReceiveProtocol.authorizePeer(tlsFingerprint:)` is a **local integration hook**, not authentication. It only checks that the hello fingerprint agrees with the fingerprint supplied by the future secure transport. The caller must already have completed mutual authentication/pairing. Tests supplying strings to this hook test ordering only; they are not TLS or pairing security tests.

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
| pairingConfirmation | transcriptDigest | Both sides; reserved for secure handshake integration |
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

Only `capture.json`, `Images/**` and `Checkpoints/**` are allowed. capture.json must be nonempty and at most 4 MiB. imageCount must agree with nonempty recognized image files directly under Images, matching current CaptureRepository semantics. Preserve filenames and subdirectories.

Paths reject absolute/traversal/dot/empty components, backslashes, colons, percent escapes, control characters, trailing dots/spaces and non-NFC byte representations. Duplicate case/diacritic-folded paths and file/directory collisions are rejected conservatively for Apple filesystems. No URL decoding is performed. Disk services must additionally reject symlinks and special files; string validation alone is insufficient.

Manifest identity is SHA-256 of JSON encoded with sorted keys, unescaped slashes and the existing ordered files array (UUID strings and UTC date strings). Use `canonicalData()` on both ends rather than hashing arbitrary received JSON formatting. Changing any field, file order, size or digest invalidates the identity.

## Receiver state and integrity

`awaitingHello → awaitingTrust → idle → offered → receiving → finalizing → completed`.

Local user decline returns offered to idle. Only the secure transport may authorize the peer; only the local receive decision accepts an offer; only the store may report finalized. Binary data before acceptance, concurrent files, duplicate verified indices, mismatched transfer IDs, bad file indices and unexpected control messages fail the session.

FileIntegrityVerifier incrementally updates CryptoKit SHA-256 and actual length in bounded chunks. Truncation, corruption and extra bytes fail; completion can be consumed only once. This primitive does not write files. Future staging must write successfully before treating the corresponding protocol fileComplete as durable.

Cancel and timeout/disconnect stop the current stream and preserve the set of fully verified file indices. A reconnect starts a new receiver protocol instance, repeats authentication, reoffers the exact manifest and asks for explicit acceptance. ResumeDescriptor binds candidate indices to transfer UUID, capture UUID and manifest digest. It is a journal model only: **persistent journaling and file rehashing are not implemented yet**. Disk existence or a journal entry alone must never cause a file to be skipped.

## Required disk integration (next checkpoints)

Resolve the ready source dataset by capture UUID through CaptureRepository. Validate ownership and files, incrementally hash/read them, and prevent or detect mutations while sending. Never use a network-provided source path. Keep the original iPhone capture intact.

Receiver staging will use app-owned `Incoming/<transferUUID>.partial`. Validate the entire manifest and free space before creating files. Persist only verified completion state; rehash candidate completed files after restart. On changed manifests, safely restart incompatible staging. Partial files restart from byte zero in version 1.

After every file verifies, extend LocalProjectStore to atomically create:

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

Decision: the Mac project UUID equals the capture UUID for version 1, making duplicate imports explicit. Transfer UUID identifies a particular manifest attempt and persists across file-level retries. Never overwrite an existing project: an identical already-imported capture should return an explicit duplicate result; a changed dataset with that UUID requires a user-visible conflict. This finalization/duplicate behavior is specified, not implemented in checkpoint A. Set captureMethod objectCapture, real source/count/date and reconstructionState notStarted. Never start photogrammetry in this milestone.

## SDK and privacy notes

Inspected Xcode 26.6 iOS 26.5 Network.swiftinterface: NWBrowser Bonjour descriptors and result/state callbacks, NWListener service/newConnectionHandler, NWConnection receive(minimumIncompleteLength:maximumLength:completion:) and send(content:contentContext:isComplete:completion:), NWParameters(tls:tcp:). Security headers expose local identity, required peer authentication, minimum TLS version, verify blocks and peer-public-key metadata. No unavailable API signature was used to implement a socket.

Before enabling networking, retain Mac App Sandbox and add only the client/server network capabilities needed by the implemented connection roles. Both apps must declare `_caliper3d._tcp` and a local-network usage explanation. iPhone already has these declarations; Mac additions remain pending with the listener. Handle denied privacy access without retry loops. Apple documents Bonjour declarations and local-network privacy, including macOS, in [TN3179](https://developer.apple.com/documentation/technotes/tn3179-understanding-local-network-privacy). No background modes or multicast entitlement were added in this checkpoint.

## Verification boundary

Tests use in-memory frames and synthetic bytes only. They cover fragmentation/coalescing, bounds, malformed/version errors, safe paths/collisions, manifest totals, incremental corruption/truncation, local authorization gating, ordering, cancel/interruption and resume identity. They do not prove TLS authentication, Keychain persistence, actual disk staging/resume, or physical transfer. The user-verified mouse scan remains outside Git and has not been sent to Mac by this implementation.
