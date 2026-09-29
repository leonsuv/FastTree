// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "FastTree",
    platforms: [.macOS(.v13)],
    products: [
        .library(name: "FastTreeCore", targets: ["FastTreeCore"]),
        .executable(name: "FastTreeApp", targets: ["FastTreeApp"])
    ],
    targets: [
        .target(name: "FastTreeCore", path: "FastTreeCore", sources: ["src/FastTreeCore.c"], publicHeadersPath: "include"),
        .executableTarget(name: "FastTreeApp", dependencies: ["FastTreeCore"], path: "FastTreeApp")
    ]
)
