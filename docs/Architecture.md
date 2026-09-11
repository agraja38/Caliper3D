# Architecture

Read PROJECT_SPEC.md for stable product decisions and IMPLEMENTATION_STATUS.md for current limitations.

| Component | Responsibility |
| --- | --- |
| Apps/Caliper3D | Native Mac navigation, library UI, RealityKit viewport, processing UI, Settings |
| Apps/Caliper3DCapture | Onboarding, capture flow UI and UI-facing state |
| Caliper3DCore | Versioned models, validation, atomic package creation/import, capture and photogrammetry protocols, logging |
| Caliper3DTransfer | Discovery and transfer protocols, isolated demo services, path policy and SHA-256 helper |
| Caliper3DMesh | Mesh processing, analysis and STL export contracts |
| Caliper3DInstaller | Read-only installation-status contract; unknown status until real integration |

## Dependencies and concurrency

Both applications depend on Core and Transfer. Mac additionally links Mesh and Installer. No package depends on either app. Services are injected at app composition or feature construction. LibraryModel, ProcessingModel and CaptureFlowModel are separate MainActor UI models. LocalProjectStore is an actor; it performs filesystem work outside MainActor. Network services currently have no socket implementation.

Production capture uses a live MainActor CaptureSessionDriver/Factory and observable CaptureSessionModel. The iOS adapter owns Apple's session and streams safe snapshots to Core; Swift Observation handles the SDK's non-Sendable tracking property on MainActor. LocalCaptureRepository owns UUID datasets and metadata. Demo CaptureService remains one-shot and isolated. See ObjectCapture.md for lifecycle and storage details.

## Package semantics

`<UUID>.caliper3d/manifest.json` uses schema 1, ISO-8601 timestamps and sorted JSON keys. User-facing names never form disk paths. Creation stages a complete package and then moves it into place. Duplicate project UUIDs cannot overwrite an existing package. Photo imports use numbered filenames and preserve source bytes. File-count and per-file bounds exist; complete file-format, aggregate-size and disk-space validation remain planned.

Opening packages reads a bounded manifest and rejects a symbolic-link package/manifest. Unknown schemas fail before payload decoding. The current opener does not consume meshes or follow manifest-controlled asset paths. Before adding asset loading, validate every path component and protect against symlink/race escapes, oversized files and malformed assets. A future migration must operate on a new package or backup rather than mutating an unsupported original.

`capture/` and `reconstruction/` are originals. Future operations write new versioned results into `processed/`; operation provenance and asset references must be added in a versioned schema migration. Current synthetic demo geometry is generated at runtime and is not saved as a reconstructed model.

## Demo boundary

Use the shared Demo schemes or `--demo-mode`. Mac demo mode injects a demo device and uses a separate library location. Try Demo Project also works in ordinary mode and creates a manifest explicitly marked `demo`. Reconstruction controls appear only for those demo projects. All simulation results are labeled, and never set a real project's reconstruction status to complete. iPhone simulator flow requires demo mode; normal mode uses the production Object Capture flow, with support and permission checks. Demo transfer rejects non-demo records.

## Next network design

Use Network.framework NWBrowser/NWListener with `_caliper3d._tcp` Bonjour service. No listener is enabled yet. Before enabling: specify protocol version, authenticated peer pairing, TLS/key lifecycle, user approval, length-prefixed bounded messages, per-file/aggregate quotas, safe paths, CryptoKit integrity checks, resumable staged transfer and atomic commit. SHA-256 alone does not authenticate a sender. No installer shell commands should be placed in UI code.
