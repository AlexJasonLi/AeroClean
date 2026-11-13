// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "AeroClean",
    platforms: [.macOS(.v14)],
    products: [
        .executable(name: "AeroClean", targets: ["AeroClean"]),
    ],
    targets: [
        .target(name: "AeroCleanCore"),
        .target(name: "AeroCleanUI", dependencies: ["AeroCleanCore"]),
        .executableTarget(name: "AeroClean", dependencies: ["AeroCleanUI", "AeroCleanCore"]),
        // renders scenes and screens to png for design review, without a window.
        .executableTarget(name: "Snapshots", dependencies: ["AeroCleanUI", "AeroCleanCore"]),
        .testTarget(name: "AeroCleanUITests", dependencies: ["AeroCleanUI"]),
        .testTarget(
            name: "AeroCleanCoreTests",
            dependencies: ["AeroCleanCore"],
            resources: [.copy("Fixtures")]
        ),
    ]
)
