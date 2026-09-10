// swift-tools-version: 5.9
import PackageDescription
let package = Package(
    name: "Caliper3DCore",
    platforms: [.macOS(.v14), .iOS(.v17)],
    products: [.library(name: "Caliper3DCore", targets: ["Caliper3DCore"])],
    dependencies: [],
    targets: [
        .target(name: "Caliper3DCore", dependencies: []),
        .testTarget(name: "Caliper3DCoreTests", dependencies: ["Caliper3DCore"])
    ]
)
