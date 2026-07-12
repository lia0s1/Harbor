// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "HarborKit",
    platforms: [
        .macOS(.v14)
    ],
    products: [
        .library(name: "HarborKit", targets: ["HarborKit"])
    ],
    targets: [
        .target(name: "HarborKit"),
        .testTarget(name: "HarborKitTests", dependencies: ["HarborKit"])
    ]
)
