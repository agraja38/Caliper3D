// swift-tools-version: 5.9
import PackageDescription
let package = Package(
    name: "Caliper3DTransfer",
    platforms: [.macOS(.v14), .iOS(.v17)],
    products: [.library(name: "Caliper3DTransfer", targets: ["Caliper3DTransfer"])],
    dependencies: [.package(path: "../Caliper3DCore")],
    targets: [
        .target(name: "Caliper3DTransfer", dependencies: [.product(name: "Caliper3DCore", package: "Caliper3DCore")]),
        .testTarget(name: "Caliper3DTransferTests", dependencies: ["Caliper3DTransfer"])
    ]
)
