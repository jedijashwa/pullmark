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
        .executableTarget(
            name: "PullMarkQuickLook",
            path: "Sources/PullMarkQuickLook",
            swiftSettings: [.swiftLanguageMode(.v5)],
            linkerSettings: [
                .linkedFramework("Quartz"),
                // App extensions enter through _NSExtensionMain, not main.
                .unsafeFlags(["-Xlinker", "-e", "-Xlinker", "_NSExtensionMain"]),
            ]
        ),
        .testTarget(
            name: "PullMarkTests",
            dependencies: ["PullMark"],
            path: "Tests/PullMarkTests",
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
    ]
)
