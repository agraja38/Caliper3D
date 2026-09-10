# Test map

Executable XCTest suites live beside each Swift package:

- Core: manifest round-trip, invalid/unknown schema, malformed data, persistence, duplicate protection, source preservation, symlink manifest rejection, demo services and cancellation.
- Transfer: safe relative paths, SHA-256 known vector, stable demo discovery, demo receipt, rejection of real input and cancellation.
- Installer: unknown status remains explicit.

Run `./Scripts/verify.sh` for all 19 tests and both app compilation checks. Mesh contains protocols only. Add app lifecycle/state and UI tests as real services arrive. See IMPLEMENTATION_STATUS.md for manual runtime checks and their limits.
