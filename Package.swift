// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "ship",
    platforms: [.macOS(.v13)],
    products: [.executable(name: "ship", targets: ["ship"])],
    targets: [
        .target(name: "ShipCore"),
        .executableTarget(name: "ship", dependencies: ["ShipCore"]),
        .testTarget(name: "ShipCoreTests", dependencies: ["ShipCore"])
    ]
)
