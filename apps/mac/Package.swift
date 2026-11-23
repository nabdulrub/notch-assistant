// swift-tools-version: 6.2
import PackageDescription

let package = Package(
    name: "Assistant",
    platforms: [.macOS(.v26)],
    dependencies: [
        // Fetches, checks and installs new versions. The only dependency.
        .package(url: "https://github.com/sparkle-project/Sparkle", from: "2.9.0"),
    ],
    targets: [
        .target(
            name: "AssistantCore",
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
        .executableTarget(
            name: "Assistant",
            dependencies: ["AssistantCore", .product(name: "Sparkle", package: "Sparkle")],
            swiftSettings: [.swiftLanguageMode(.v5)],
            // Inside the app bundle the framework sits in Contents/Frameworks.
            linkerSettings: [.unsafeFlags(["-Xlinker", "-rpath", "-Xlinker", "@executable_path/../Frameworks"])]
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
