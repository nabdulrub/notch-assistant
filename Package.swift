// swift-tools-version: 6.2
import PackageDescription

let package = Package(
    name: "Assistant",
    platforms: [.macOS(.v26)],
    targets: [
        .target(
            name: "AssistantCore",
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
        .executableTarget(
            name: "Assistant",
            dependencies: ["AssistantCore"],
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
        .executableTarget(
            name: "AssistantChannel",
            dependencies: ["AssistantCore"],
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
        .testTarget(
            name: "AssistantCoreTests",
            dependencies: ["AssistantCore"],
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
    ]
)
