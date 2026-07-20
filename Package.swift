// swift-tools-version: 6.0

import PackageDescription

let package = Package(
    name: "IdeaForge",
    platforms: [
        .macOS(.v14),
        .iOS(.v17),
        .watchOS(.v10)
    ],
    products: [
        .library(name: "IdeaForgeCore", targets: ["IdeaForgeCore"])
    ],
    targets: [
        .target(name: "IdeaForgeCore", path: "Sources/IdeaForgeCore"),
        .testTarget(
            name: "IdeaForgeCoreTests",
            dependencies: ["IdeaForgeCore"],
            path: "Tests/IdeaForgeCoreTests",
            resources: [
                .process("Fixtures")
            ]
        )
    ]
)
