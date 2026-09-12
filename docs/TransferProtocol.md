# Local capture transfer protocol — version 1

Session 3 implements transport-independent protocol/integrity logic plus TLS, identity and pairing components. **Production discovery/listening, pairing UI, source enumeration, disk staging and capture transfer are not integrated yet.** Loopback TLS tests are not a real phone-to-Mac dataset transfer.

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

This uses standard hashes/MACs and TLS channel binding, not custom encryption. Commit/reveal prevents adaptive nonce selection after seeing the peer's nonce. The short code provides approximately 20 bits of human verification, not unlimited-attempt authentication. Before production exposure add connection/attempt rate limits and enforce one active pairing UI; independent security review of the composition remains advisable. Users must compare the code on their own two devices. No approval or automatic trust may come from a Bonjour advertisement.

ReceiveProtocol.authorizePeer remains a local integration hook. The future coordinator must first complete PairingSession approval (or match a stored pin on reconnect), ensure its hello fingerprint matches TLSBinding, and await Keychain persistence before granting transfer authorization. Pairing messages do not directly authorize ReceiveProtocol. Discovery, pairing UI and that coordinator are not yet implemented.

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

Inspected Xcode 26.6 iOS 26.5 Network.swiftinterface: NWBrowser Bonjour descriptors and result/state callbacks, NWListener service/newConnectionHandler, NWConnection receive(minimumIncompleteLength:maximumLength:completion:) and send(content:contentContext:isComplete:completion:), NWParameters(tls:tcp:). Security headers expose local identity, required peer authentication, minimum TLS version, verify blocks and peer-public-key metadata. SecIdentityCreate and TLS exporter signatures were also checked in Security headers. The implemented channel compiles against the installed SDK and has loopback socket tests.

Before enabling networking, retain Mac App Sandbox and add only the client/server network capabilities needed by the implemented connection roles. Both apps must declare `_caliper3d._tcp` and a local-network usage explanation. iPhone already has these declarations; Mac additions remain pending with the listener. Handle denied privacy access without retry loops. Apple documents Bonjour declarations and local-network privacy, including macOS, in [TN3179](https://developer.apple.com/documentation/technotes/tn3179-understanding-local-network-privacy). No background modes or multicast entitlement were added in this checkpoint.

## Verification boundary

Most tests use in-memory frames and synthetic bytes. Two additional tests use real Network.framework TLS loopback connections without Bonjour advertisements. They cover fragmentation/coalescing, bounds, malformed/version errors, safe paths/collisions, manifest totals, incremental corruption/truncation, local authorization gating, ordering, cancel/interruption and resume identity. Loopback tests verify matching live TLS exporters/codes, a bounded binary payload and pinned mismatch rejection. Security identity tests verify certificate parsing/trust and private-key proof. They do not prove signed-app Keychain persistence, Bonjour, actual disk staging/resume, or physical transfer. The user-verified mouse scan remains outside Git and has not been sent to Mac by this implementation.
