# Caliper3D

**Caliper3D turns a LiDAR-equipped iPhone and a Mac into an open-source 3D scanning workflow for creating clean, printable STL models.**

Native Swift and SwiftUI. Local-first. No accounts or cloud backend.

## Development status

This is a working **foundation and demo release**, not yet a functioning physical object scanner.

Implemented: macOS Library/New Scan/Devices/Processing navigation, local project creation and photo import/opening, an adjustable RealityKit demo viewport, Settings, a simulated reconstruction job with cancellation, iPhone onboarding and demo capture/review/transfer, shared packages, schema validation and tests.

Planned: real Object Capture, secure Mac–iPhone pairing and file transfer, real Mac photogrammetry, mesh cleanup/smoothing, measurements/calibration, STL export and companion installation. Unimplemented production actions are hidden or clearly explained.

## Intended workflow

Connect iPhone → scan object → transfer locally → reconstruct on Mac → clean mesh → measure/calibrate → export STL.

The iPhone is the capture device; the Mac handles heavy processing. Original captures and reconstruction outputs will remain preserved.

## Build and try

Requirements: a Mac with Xcode (verified with Xcode 26.6 / Swift 6.3.3). Deployment targets: macOS 14+, iOS 17+. A compatible physical iPhone will be required for future real Object Capture; no iPhone is required for demo development.

1. Clone the repository and check out `development`.
2. Open `Caliper3D.xcworkspace` in Xcode.
3. Choose **Caliper3D Demo** and My Mac, or **Caliper3DCapture Demo** and an iPhone Simulator.
4. Run. On Mac, choose **Try Demo Project**, rotate/zoom the block, open Project Info, and simulate reconstruction. On iPhone, finish onboarding, choose New Scan, then simulate transfer.

The demo schemes pass `--demo-mode`. Ordinary schemes never invent connected hardware. iPhone recent demo captures are temporary. Mac demo packages persist separately from ordinary projects. The apps do not actually exchange demo data.

For physical installation, configure your own signing team in Xcode. No team ID is committed. Bundle IDs default to `org.caliper3d.Caliper3D` and `org.caliper3d.Caliper3DCapture` and can be overridden in build settings.

```sh
./Scripts/verify.sh
```

This runs package tests, builds the mesh contract module, and compiles both applications without signing. The checked-in Xcode project is ready to build. If changing `project.yml`, install XcodeGen and run `xcodegen generate`.

## Architecture

- `Apps/Caliper3D`: Mac application.
- `Apps/Caliper3DCapture`: iPhone companion.
- `Packages/Caliper3DCore`: shared models, storage and service contracts.
- `Packages/Caliper3DTransfer`: discovery/transfer boundaries and demo services.
- `Packages/Caliper3DMesh`: processing/analysis/export contracts.
- `Packages/Caliper3DInstaller`: installation-status boundary.

Projects are versioned `.caliper3d` packages containing `manifest.json`, `capture/`, `reconstruction/`, `processed/`, `thumbnails/` and `logs/`.

See [architecture](docs/Architecture.md), [environment](docs/Environment.md), [project specification](PROJECT_SPEC.md), [implementation status](IMPLEMENTATION_STATUS.md) and [next steps](NEXT_STEPS.md).

## Privacy

No telemetry, analytics, accounts or remote processing. Imported photos retain their metadata and remain local. No camera or network services are activated in this foundation. See [Privacy](docs/Privacy.md) and [Security](SECURITY.md).

## Roadmap

1. Real iPhone Object Capture with compatibility, permissions, feedback and persistent review.
2. Authenticated local transfer and RealityKit reconstruction on Mac.
3. Non-destructive mesh cleanup and calibrated measurements.
4. Printable STL export and safe companion setup.

## Contributing and license

Use `development` and read [CONTRIBUTING.md](CONTRIBUTING.md). MIT licensed; see [LICENSE](LICENSE).
