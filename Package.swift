// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "MacCleaner",
    platforms: [.macOS(.v14)],
    products: [
        .executable(name: "MacCleaner", targets: ["MacCleaner"]),
    ],
    targets: [
        .target(name: "MacCleanerCore"),
        .target(name: "MacCleanerUI", dependencies: ["MacCleanerCore"]),
        .executableTarget(name: "MacCleaner", dependencies: ["MacCleanerUI", "MacCleanerCore"]),
        // renders scenes and screens to png for design review, without a window.
        .executableTarget(name: "Snapshots", dependencies: ["MacCleanerUI", "MacCleanerCore"]),
        .testTarget(name: "MacCleanerUITests", dependencies: ["MacCleanerUI"]),
        .testTarget(
            name: "MacCleanerCoreTests",
            dependencies: ["MacCleanerCore"],
            resources: [.copy("Fixtures")]
        ),
    ]
)
