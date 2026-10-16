// swift-tools-version: 5.10
import PackageDescription

let package = Package(
    name: "Harbor",
    platforms: [.macOS(.v14)],
    products: [
        .library(name: "HarborCore", targets: ["HarborCore"]),
        .executable(name: "harbor", targets: ["harbor"]),
        .executable(name: "HarborApp", targets: ["HarborApp"]),
    ],
    targets: [
        .target(name: "HarborCore"),
        .executableTarget(name: "harbor", dependencies: ["HarborCore"]),
        .executableTarget(name: "HarborApp", dependencies: ["HarborCore"]),
        .testTarget(name: "HarborCoreTests", dependencies: ["HarborCore"]),
    ]
)
