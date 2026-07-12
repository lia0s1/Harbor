// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "HarborMCP",
    platforms: [.macOS(.v14)],
    products: [
        .executable(name: "harbor-mcp", targets: ["HarborMCP"]),
    ],
    dependencies: [
        .package(path: "../HarborKit"),
    ],
    targets: [
        .executableTarget(
            name: "HarborMCP",
            dependencies: [
                .product(name: "HarborKit", package: "HarborKit"),
            ]
        ),
        .testTarget(
            name: "HarborMCPTests",
            dependencies: ["HarborMCP"]
        ),
    ]
)
