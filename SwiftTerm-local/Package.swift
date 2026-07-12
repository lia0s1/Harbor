// swift-tools-version:5.9

import PackageDescription
import Foundation

#if os(Linux) || os(Windows)
let platformExcludes = ["Apple", "Mac", "iOS"]
#else
let platformExcludes: [String] = []
#endif

// Keep embedding-library and test builds independent of remote development tooling.
let includeDevelopmentTargets = ProcessInfo.processInfo.environment["SWIFTTERM_INCLUDE_DEVELOPMENT_TARGETS"] == "1"

#if os(Windows)
let packageDependencies: [Package.Dependency] = []
let products: [Product] = [
    .executable(name: "SwiftTermFuzz", targets: ["SwiftTermFuzz"]),
    .library(
        name: "SwiftTerm",
        targets: ["SwiftTerm"]
    ),
]

let targets: [Target] = [
    .target(
        name: "SwiftTerm",
        dependencies: [],
        path: "Sources/SwiftTerm",
        exclude: platformExcludes + ["Mac/README.md"]
//        swiftSettings: [
//            .unsafeFlags(["-enforce-exclusivity=none"])
//        ]
    ),
    .executableTarget (
        name: "SwiftTermFuzz",
        dependencies: ["SwiftTerm"],
        path: "Sources/SwiftTermFuzz"
    ),
    .testTarget(
        name: "SwiftTermTests",
        dependencies: ["SwiftTerm"],
        path: "Tests/SwiftTermTests"
    )
]
#else
let packageDependencies: [Package.Dependency] = includeDevelopmentTargets ? [
    .package(url: "https://github.com/apple/swift-argument-parser", exact: "1.7.0"),
    .package(url: "https://github.com/apple/swift-docc-plugin", exact: "1.4.6"),
    .package(url: "https://github.com/ordo-one/package-benchmark", exact: "1.29.11")
] : []

let products: [Product] = [
    .executable(name: "SwiftTermFuzz", targets: ["SwiftTermFuzz"]),
    .library(
        name: "SwiftTerm",
        targets: ["SwiftTerm"]
    ),
] + (includeDevelopmentTargets ? [
    .executable(name: "termcast", targets: ["Termcast"])
] : [])

let developmentTargets: [Target] = includeDevelopmentTargets ? [
    .executableTarget (
        name: "Termcast",
        dependencies: [
            "SwiftTerm",
            .product(name: "ArgumentParser", package: "swift-argument-parser")
        ],
        path: "Sources/Termcast"
    ),
    .executableTarget(
        name: "SwiftTermBenchmarks",
        dependencies: [
            "SwiftTerm",
            .product(name: "Benchmark", package: "package-benchmark")
        ],
        path: "Benchmarks/SwiftTermBenchmarks",
        plugins: [
            .plugin(name: "BenchmarkPlugin", package: "package-benchmark")
        ]
    )
] : []

let targets: [Target] = [
    .target(
        name: "SwiftTerm",
        //
        // We can not use Swift Subprocess, because there is no way of configuring the child process to
        // be a controlling terminal, as it is posix-spawn based.
//        dependencies: [
//            .product(name: "Subprocess", package: "swift-subprocess", condition: .when(platforms: [.macOS, .linux]))
//        ],
        path: "Sources/SwiftTerm",
        exclude: platformExcludes + ["Mac/README.md", "Apple/Metal/Shaders.metal"],
        resources: [.copy("Apple/Metal/Shaders.metal.txt")]
//        swiftSettings: [
//            .unsafeFlags(["-enforce-exclusivity=none"])
//        ]
    ),
    .executableTarget (
        name: "SwiftTermFuzz",
        dependencies: ["SwiftTerm"],
        path: "Sources/SwiftTermFuzz"
    ),
    .testTarget(
        name: "SwiftTermTests",
        dependencies: ["SwiftTerm"],
        path: "Tests/SwiftTermTests"
    )
] + developmentTargets
#endif

let package = Package(
    name: "SwiftTerm",
    platforms: [
        .iOS(.v14),
        .macOS(.v13),
        .tvOS(.v13),
        .visionOS(.v1)
    ],
    products: products,
    dependencies: packageDependencies,
//        .package(url: "https://github.com/swiftlang/swift-subprocess", revision: "426790f3f24afa60b418450da0afaa20a8b3bdd4")
    targets: targets,
    swiftLanguageVersions: [.v5]
)
