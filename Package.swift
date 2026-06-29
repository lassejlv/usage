// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "Usage",
    platforms: [
        .macOS(.v13)
    ],
    targets: [
        .executableTarget(
            name: "Usage",
            path: "Sources/Usage",
            resources: [
                .process("Resources")
            ]
        )
    ]
)
