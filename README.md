# Caliper3D

**Caliper3D turns a LiDAR-equipped iPhone and a Mac into an open-source 3D scanning workflow for creating clean, printable STL models.**

Native Swift and SwiftUI. Local-first. No accounts or cloud backend.

## Install v1.0.0

[Download Caliper3D-1.0.0.dmg](https://github.com/agraja38/Caliper3D/releases/download/v1.0.0/Caliper3D-1.0.0.dmg) · [Release notes and checksums](https://github.com/agraja38/Caliper3D/releases/tag/v1.0.0)

Requires **macOS 14+**, on Apple Silicon or Intel. No Xcode is needed for the Mac download. Install from Terminal with this single command:

```sh
curl -fsSL https://github.com/agraja38/Caliper3D/releases/download/v1.0.0/install.sh | /bin/bash
```

The installer verifies the DMG’s SHA-256 checksum, installs to `~/Applications/Caliper3D.app`, and refuses to overwrite an existing app. It does not use sudo or disable macOS security protections. You can inspect [the installer](Scripts/install.sh) before running it, or open the DMG and drag the app into Applications.

**Signing:** this release is ad-hoc signed, not Developer ID signed or notarized. macOS may block first launch; after reviewing the download, use the normal **System Settings → Privacy & Security → Open Anyway** workflow if offered ([Apple’s instructions](https://support.apple.com/en-ca/guide/mac-help/mh40616/mac)). The checksum detects download corruption; it is not a Developer ID identity guarantee.

**v1.0.0 is the foundation/demo release.** Choose **Try Demo Project** to explore the Mac app. Real scanning, transfer, reconstruction and STL export are still planned. The DMG contains the Mac app; the iPhone companion currently requires building from source.

## Development status

**Current main includes the production iPhone Object Capture pipeline and persistent captures. The user has verified a real mouse scan through review and app relaunch. Secure Mac transfer is still under development.** The published v1.0.0 DMG remains the foundation/demo release.

Implemented: macOS Library/New Scan/Devices/Processing navigation, local project creation and photo import/opening, an adjustable RealityKit demo viewport, Settings, a simulated reconstruction job with cancellation, iPhone onboarding and demo capture/review/transfer, shared packages, schema validation and tests.

Implemented on main: live iPhone capture support/permission checks, guided RealityKit scanning, file-backed review, rename and deletion; see [Object Capture status](docs/ObjectCapture.md).

Planned: secure Mac–iPhone pairing and file transfer, real Mac photogrammetry, mesh cleanup/smoothing, measurements/calibration, STL export and companion installation. Unimplemented production actions are hidden or clearly explained.

## Intended workflow

Connect iPhone → scan object → transfer locally → reconstruct on Mac → clean mesh → measure/calibrate → export STL.

The iPhone is the capture device; the Mac handles heavy processing. Original captures and reconstruction outputs will remain preserved.

## Build and try

Requirements: a Mac with Xcode (verified with Xcode 26.6 / Swift 6.3.3). Deployment targets: macOS 14+, iOS 17+. A compatible physical iPhone will be required for future real Object Capture; no iPhone is required for demo development.

1. Clone the repository and check out `main`.
2. Open `Caliper3D.xcworkspace` in Xcode.
3. Choose **Caliper3D Demo** and My Mac, or **Caliper3DCapture Demo** and an iPhone Simulator.
4. Run. On Mac, choose **Try Demo Project**, rotate/zoom the block, open Project Info, and simulate reconstruction. On iPhone, finish onboarding, choose New Scan, then simulate transfer.

The demo schemes pass `--demo-mode`. Ordinary schemes never invent connected hardware. iPhone recent demo captures are temporary. Mac demo packages persist separately from ordinary projects. The apps do not actually exchange demo data.

For physical installation, configure your own signing team in Xcode. No team ID is committed. Bundle IDs default to `org.caliper3d.Caliper3D` and `org.caliper3d.Caliper3DCapture` and can be overridden in build settings.

```sh
./Scripts/verify.sh
```

This runs package tests, builds the mesh contract module, and compiles both applications without signing. The checked-in Xcode project is ready to build. If changing `project.yml`, install XcodeGen and run `xcodegen generate`.

## Set up Caliper3D Capture on iPhone

The iPhone companion is built from source using Xcode; the Mac DMG and terminal installer do not install it. **The released v1.0.0 source provides a demo workflow. Current main also implements real Object Capture, with the basic physical capture workflow verified.** Mac pairing remains unimplemented.

### Get the source

Install Xcode on your Mac, open it once to finish setup, and install its iOS platform components if prompted. Use an Xcode version that supports your iPhone’s installed iOS version; this project was built with Xcode 26.6. The companion targets iOS 17 or later.

```sh
git clone https://github.com/agraja38/Caliper3D.git
cd Caliper3D
git switch main
open Caliper3D.xcworkspace
```

If you already cloned the repository, open that workspace instead. XcodeGen is not required to build the checked-in project.

### Try it without an iPhone

1. In Xcode’s toolbar, choose the **Caliper3DCapture Demo** scheme.
2. Select an **iPhone Simulator** as the run destination. Download an iOS Simulator runtime in **Xcode → Settings → Components** if none is available.
3. Choose **Product → Run** or press **⌘R**. Simulator runs do not require an Apple signing team.
4. Complete the three onboarding pages, tap **Get Started**, then **New Scan**.
5. Wait for the simulated capture, review it, then tap **Simulate Transfer to Mac**. Completion explicitly confirms that no data was sent.

Demo captures are temporary metadata, reset when the app closes, and do not use a camera or LiDAR. If Xcode reports a missing iOS platform despite an installed SDK, see the tested workaround in [Environment.md](docs/Environment.md#simulator-destination-issue-and-workaround).

### Install on your physical iPhone

1. Connect your unlocked iPhone to the Mac with a USB cable. Accept **Trust This Computer** on the iPhone if prompted, and allow Xcode to finish preparing the device.
2. In **Xcode → Settings → Apple Accounts** (called **Accounts** in some versions), sign in with your own Apple Account. A Personal Team can be used for personal device testing.
3. Select the blue **Caliper3D** project in the navigator, then **TARGETS → Caliper3DCapture → Signing & Capabilities**. Enable **Automatically manage signing** and select your own **Team**.
4. If Xcode reports that the bundle identifier is unavailable, change the iPhone target’s identifier to a unique value such as `com.yourname.Caliper3DCapture`. Keep personal signing changes local.
5. Enable **Settings → Privacy & Security → Developer Mode** on the iPhone when required. Restart and confirm when prompted. If the setting is absent, connect the phone to Xcode first. See [Apple’s Developer Mode instructions](https://developer.apple.com/documentation/xcode/enabling-developer-mode-on-a-device).
6. Choose **Caliper3DCapture Demo** and select your **physical iPhone** as the destination. Press **⌘R** to build, install and launch.
7. Complete onboarding and try **New Scan → review → Simulate Transfer to Mac**.

For device preparation and signing details, see [Apple’s device-running guide](https://developer.apple.com/documentation/xcode/running-your-app-on-simulated-or-physical-devices). Personal development provisioning can expire; if the app stops launching, reconnect and run it from Xcode again.

The Demo scheme supplies `--demo-mode` when **Xcode launches the app**. Opening it later from the iPhone Home Screen does not supply that argument; launch through the Demo scheme to use the simulated flow. To test real capture from current main, use the ordinary **Caliper3DCapture** scheme: **New Scan → allow camera access → Start Detection → adjust the object selection → Start Capturing → Finish Scan**. Completion waits for RealityKit and then opens the saved review. Unsupported devices and Simulator show an availability explanation. Read [the device validation checklist](docs/ObjectCapture.md#verification-and-outstanding-device-run) before treating the pipeline as verified.

### Explore the Mac side

Open Caliper3D on the Mac and choose **Try Demo Project**. There is no pairing code or network setup in v1.0.0, and the two apps do not exchange captures yet. Physical installation instructions above have not been device-tested in this project; the Simulator demo flow has been verified.

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

No telemetry, analytics, accounts or remote processing. Imported photos retain their metadata and remain local. The released foundation is demo-only; current main can activate Object Capture after permission on supported iPhones. No network transfer is active. See [Privacy](docs/Privacy.md) and [Security](SECURITY.md).

## Roadmap

1. Complete secure local transfer from the verified iPhone capture pipeline to a Mac project.
2. Authenticated local transfer and RealityKit reconstruction on Mac.
3. Non-destructive mesh cleanup and calibrated measurements.
4. Printable STL export and safe companion setup.

## Contributing and license

Use `main` and read [CONTRIBUTING.md](CONTRIBUTING.md). MIT licensed; see [LICENSE](LICENSE).
