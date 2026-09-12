# Test map

Executable XCTest suites live beside each Swift package:

- Core: manifest round-trip, invalid/unknown schema, malformed data, persistence, duplicate protection, source preservation, symlink manifest rejection, demo services and cancellation.
- Transfer: safe relative paths, SHA-256 known vector, stable demo discovery, demo receipt, rejection of real input and cancellation.
- Installer: unknown status remains explicit.

Run `./Scripts/verify.sh` for all package tests and both app compilation checks. Mesh contains protocols only. Add app lifecycle/state and UI tests as real services arrive. See IMPLEMENTATION_STATUS.md for manual runtime checks and their limits.

Session 2 adds capture repository and live lifecycle suites: legacy/real metadata, empty unique allocation, completion/file statistics, persistence, rename, safe deletion and symlink ancestors, corrupt metadata, low disk, thumbnails, incomplete preservation, permission gating, late-cancellation protection, state/action rules, pass/flip, background pause and save retry. These use synthetic fixtures and fake session drivers, never Apple's camera. `swift test --package-path Packages/Caliper3DCore -Xswiftc -strict-concurrency=complete` checks the Core boundary under complete concurrency diagnostics.

Session 3 adds in-memory wire framing, manifest/path/resource validation, streamed SHA-256, receiver ordering and resume identity tests. These do not exercise TLS, Keychain, disk staging or physical transfer. Run `swift test --package-path Packages/Caliper3DTransfer -Xswiftc -strict-concurrency=complete` for complete concurrency diagnostics.
