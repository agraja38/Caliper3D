// swift-tools-version: 5.9
import PackageDescription
let package = Package(
    name: "Caliper3DInstaller",
    platforms: [.macOS(.v14), .iOS(.v17)],
    products: [.library(name: "Caliper3DInstaller", targets: ["Caliper3DInstaller"])],
    dependencies: [.package(path: "../Caliper3DCore")],
    targets: [
        .target(name: "Caliper3DInstaller", dependencies: [.product(name: "Caliper3DCore", package: "Caliper3DCore")]),
        .testTarget(name: "Caliper3DInstallerTests", dependencies: ["Caliper3DInstaller"])
    ]
)
