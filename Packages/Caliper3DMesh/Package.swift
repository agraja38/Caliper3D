// swift-tools-version: 5.9
import PackageDescription
let package = Package(
    name: "Caliper3DMesh",
    platforms: [.macOS(.v14), .iOS(.v17)],
    products: [.library(name: "Caliper3DMesh", targets: ["Caliper3DMesh"])],
    dependencies: [.package(path: "../Caliper3DCore")],
    targets: [
        .target(name: "Caliper3DMesh", dependencies: [.product(name: "Caliper3DCore", package: "Caliper3DCore")])
    ]
)
