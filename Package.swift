// swift-tools-version:6.0
import PackageDescription

let package = Package(
    name: "PullMark",
    platforms: [.macOS(.v13)],
    targets: [
        .executableTarget(
            name: "PullMark",
            path: "Sources/PullMark",
            resources: [.copy("Resources")],
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
        .testTarget(
            name: "PullMarkTests",
            dependencies: ["PullMark"],
            path: "Tests/PullMarkTests",
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
    ]
)
